package main

import (
	"bufio"
	_ "embed"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"runtime/debug"
	"strings"
)

//go:embed Dockerfile
var dockerfile []byte

const imageName = "claude-code-sandbox"

var nonAlphanumeric = regexp.MustCompile(`[^a-zA-Z0-9]+`)

var nameFlag = flag.String("name", "", "override the container name")
var imageFlag = flag.String("image", "", "override the Docker image (default: claude-code-sandbox)")
var shellFlag = flag.Bool("shell", false, "start the container as root with /bin/bash instead of claude")
var debugFlag = flag.Bool("debug", false, "alias for -shell (deprecated)")
var continueFlag = flag.Bool("continue", false, "resume the most recent claude session")
var resumeFlag = flag.Bool("resume", false, "open the session picker to resume a session")
var resumeSessionFlag = flag.String("resume-session", "", "resume a specific session by name or ID")
var sessionIDFlag = flag.String("session-id", "", "resume a specific session by UUID")
var sessionFlag = flag.String("session", "", "set a display name for the claude session")
var commitFlag = flag.String("commit", "", "commit the current container as a new image (default: claude-code-sandbox-{dirname})")
var versionFlag = flag.Bool("version", false, "print version and exit")
var updateFlag = flag.Bool("update", false, "update to the latest version via go install")

// commitFlagSet tracks whether -commit was explicitly passed (to distinguish "" from not passed).
var commitFlagSet bool

func init() {
	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, "Usage: claude-code-sandbox [flags] [-- claude-args...]\n\n")
		fmt.Fprintf(os.Stderr, "Run Claude Code in a sandboxed Docker container.\n\n")
		fmt.Fprintf(os.Stderr, "Flags:\n")
		flag.PrintDefaults()
	}
}

func version() string {
	if info, ok := debug.ReadBuildInfo(); ok && info.Main.Version != "" {
		return info.Main.Version
	}
	return "(devel)"
}

func isShellMode() bool {
	return *shellFlag || *debugFlag
}

func effectiveImage() string {
	if *imageFlag != "" {
		return *imageFlag
	}
	return imageName
}

func claudeArgs() []string {
	args := []string{"claude", "--dangerously-skip-permissions"}
	if *continueFlag {
		args = append(args, "--continue")
	}
	if *resumeFlag {
		args = append(args, "--resume")
	}
	if *resumeSessionFlag != "" {
		args = append(args, "--resume", *resumeSessionFlag)
	}
	if *sessionIDFlag != "" {
		args = append(args, "--session-id", *sessionIDFlag)
	}
	if *sessionFlag != "" {
		args = append(args, "--name", *sessionFlag)
	}
	args = append(args, flag.Args()...)
	return args
}

func cwdSlug() string {
	cwd, err := os.Getwd()
	if err != nil {
		cwd = "default"
	}
	slug := strings.ToLower(nonAlphanumeric.ReplaceAllString(cwd, "-"))
	return strings.Trim(slug, "-")
}

func containerName() string {
	if *nameFlag != "" {
		return *nameFlag
	}
	return "claude-sandbox-" + cwdSlug()
}

func main() {
	flag.Parse()

	if *versionFlag {
		fmt.Println("claude-code-sandbox " + version())
		return
	}

	if *updateFlag {
		fmt.Fprintln(os.Stderr, "Updating claude-code-sandbox...")
		cmd := exec.Command("go", "install", "github.com/mertenvg/claude-code-sandbox@latest")
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		if err := cmd.Run(); err != nil {
			fmt.Fprintf(os.Stderr, "error: %v\n", err)
			os.Exit(1)
		}
		fmt.Fprintln(os.Stderr, "Updated successfully.")
		return
	}

	// Track whether -commit was explicitly passed.
	flag.Visit(func(f *flag.Flag) {
		if f.Name == "commit" {
			commitFlagSet = true
		}
	})

	if commitFlagSet {
		if err := commitContainer(); err != nil {
			fmt.Fprintf(os.Stderr, "error: %v\n", err)
			os.Exit(1)
		}
		return
	}

	if err := ensureImage(); err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}

	if err := run(); err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			os.Exit(exitErr.ExitCode())
		}
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
}

func commitContainer() error {
	name := containerName()
	if !containerExists(name) {
		return fmt.Errorf("container %q does not exist", name)
	}

	commitImage := *commitFlag
	if commitImage == "" {
		commitImage = imageName + "-" + cwdSlug()
	}

	fmt.Fprintf(os.Stderr, "Committing container %q as image %q...\n", name, commitImage)
	cmd := exec.Command("docker", "commit", name, commitImage)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("committing container: %w", err)
	}

	fmt.Fprintf(os.Stderr, "Done. Use -image %s to start a new container from this image.\n", commitImage)
	return nil
}

func ensureImage() error {
	img := effectiveImage()
	check := exec.Command("docker", "image", "inspect", img)
	check.Stdout = nil
	check.Stderr = nil
	if check.Run() == nil {
		return nil
	}

	// Custom images must already exist — only auto-build the default image.
	if *imageFlag != "" {
		return fmt.Errorf("image %q not found — build or pull it first", img)
	}

	fmt.Fprintln(os.Stderr, "Building sandbox image (one-time setup)...")

	tmpDir, err := os.MkdirTemp("", "claude-sandbox-*")
	if err != nil {
		return fmt.Errorf("creating temp dir: %w", err)
	}
	defer os.RemoveAll(tmpDir)

	if err := os.WriteFile(tmpDir+"/Dockerfile", dockerfile, 0644); err != nil {
		return fmt.Errorf("writing Dockerfile: %w", err)
	}

	build := exec.Command("docker", "build", "-t", img, tmpDir)
	build.Stdout = os.Stdout
	build.Stderr = os.Stderr
	if err := build.Run(); err != nil {
		return fmt.Errorf("building image: %w", err)
	}
	return nil
}

func containerExists(name string) bool {
	check := exec.Command("docker", "container", "inspect", name)
	check.Stdout = nil
	check.Stderr = nil
	return check.Run() == nil
}

func containerRunning(name string) bool {
	out, err := exec.Command("docker", "inspect", "-f", "{{.State.Running}}", name).Output()
	if err != nil {
		return false
	}
	return strings.TrimSpace(string(out)) == "true"
}

func run() error {
	name := containerName()

	if isShellMode() {
		if containerRunning(name) {
			fmt.Fprintln(os.Stderr, "Attaching debug shell to running container...")
			return execContainer(name)
		}
		if containerExists(name) {
			fmt.Fprintln(os.Stderr, "Starting stopped container and attaching debug shell...")
			if err := startContainerDetached(name); err != nil {
				return fmt.Errorf("starting container: %w", err)
			}
			if !containerRunning(name) {
				// Old container format — recreate for debug
				_ = exec.Command("docker", "rm", name).Run()
				fmt.Fprintln(os.Stderr, "Recreating container in new format...")
				return createContainer(name)
			}
			return execContainer(name)
		}
		fmt.Fprintln(os.Stderr, "Creating new sandbox container in debug mode...")
		return createContainer(name)
	}

	if containerExists(name) {
		fmt.Fprintln(os.Stderr, "Restarting existing sandbox container...")
		return startContainer(name)
	}

	fmt.Fprintln(os.Stderr, "Creating new sandbox container...")
	return createContainer(name)
}

func startContainer(name string) error {
	if !containerRunning(name) {
		if err := startContainerDetached(name); err != nil {
			return fmt.Errorf("starting container: %w", err)
		}
		// Old containers had "claude ..." as CMD and may exit immediately.
		// Detect this and prompt the user before removing.
		if !containerRunning(name) {
			fmt.Fprintln(os.Stderr, "Container uses an older format and needs to be recreated for session management support.")
			fmt.Fprintln(os.Stderr, "Any state outside /workspace (installed packages, auth) will be lost.")
			fmt.Fprintln(os.Stderr, "Tip: run 'claude-code-sandbox -commit <image-name>' first to preserve state,")
			fmt.Fprintln(os.Stderr, "then use -image <image-name> to reuse it.")
			fmt.Fprint(os.Stderr, "Recreate? [y/N] ")

			reader := bufio.NewReader(os.Stdin)
			answer, _ := reader.ReadString('\n')
			answer = strings.TrimSpace(answer)
			if answer != "y" && answer != "Y" {
				fmt.Fprintln(os.Stderr, "Using legacy mode. Session flags will be ignored.")
				return startContainerLegacy(name)
			}
			_ = exec.Command("docker", "rm", name).Run()
			return createContainer(name)
		}
	}
	err := execClaude(name)
	_ = exec.Command("docker", "stop", name).Run()
	return err
}

func startContainerLegacy(name string) error {
	cmd := exec.Command("docker", "start", "-a", "-i", name)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func startContainerDetached(name string) error {
	return exec.Command("docker", "start", name).Run()
}

func execClaude(name string) error {
	dockerArgs := []string{"exec", "-i"}
	if isTerminal(os.Stdin) {
		dockerArgs = append(dockerArgs, "-t")
	}
	dockerArgs = append(dockerArgs, name)
	dockerArgs = append(dockerArgs, claudeArgs()...)

	cmd := exec.Command("docker", dockerArgs...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func execContainer(name string) error {
	args := []string{"exec", "-i", "-u", "0"}
	if isTerminal(os.Stdin) {
		args = append(args, "-t")
	}
	args = append(args, name, "/bin/bash")
	args = append(args, flag.Args()...)

	cmd := exec.Command("docker", args...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func createContainer(name string) error {
	cwd, err := os.Getwd()
	if err != nil {
		return fmt.Errorf("getting working directory: %w", err)
	}

	img := effectiveImage()
	args := []string{"run", "-d", "--name", name}
	args = append(args, "-v", cwd+":/workspace", "-w", "/workspace")

	if key := os.Getenv("ANTHROPIC_API_KEY"); key != "" {
		args = append(args, "-e", "ANTHROPIC_API_KEY="+key)
	}

	if isShellMode() {
		args = append(args, "-u", "0")
	}

	args = append(args, img, "sleep", "infinity")

	create := exec.Command("docker", args...)
	create.Stdout = os.Stdout
	create.Stderr = os.Stderr
	if err := create.Run(); err != nil {
		return fmt.Errorf("creating container: %w", err)
	}

	if isShellMode() {
		err = execContainer(name)
	} else {
		err = execClaude(name)
	}

	_ = exec.Command("docker", "stop", name).Run()
	return err
}

func isTerminal(f *os.File) bool {
	fi, err := f.Stat()
	if err != nil {
		return false
	}
	return fi.Mode()&os.ModeCharDevice != 0
}
