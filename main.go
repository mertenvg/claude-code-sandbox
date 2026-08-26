package main

import (
	"bufio"
	"embed"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"runtime"
	"runtime/debug"
	"strings"
)

//go:embed dockerfiles
var dockerfiles embed.FS

const (
	// imageRepo is the registry repository holding the prebuilt bundle images.
	imageRepo = "ghcr.io/mertenvg/claude-code-sandbox"
	// commitImagePrefix names images produced by -commit; kept separate from
	// imageRepo so committed images stay local and unqualified.
	commitImagePrefix = "claude-code-sandbox"
	defaultBundle     = "go"
)

var nonAlphanumeric = regexp.MustCompile(`[^a-zA-Z0-9]+`)

var nameFlag = flag.String("name", "", "override the container name")
var imageFlag = flag.String("image", "", "override the Docker image (default: "+imageRepo+":"+defaultBundle+")")
var bundleFlag = flag.String("bundle", defaultBundle, "image bundle to pull or build (see dockerfiles/)")
var pullFlag = flag.Bool("pull", false, "pull the latest bundle image before running")
var shellFlag = flag.Bool("shell", false, "start the container as root with /bin/bash instead of claude")
var debugFlag = flag.Bool("debug", false, "alias for -shell (deprecated)")
var continueFlag = flag.Bool("continue", false, "resume the most recent claude session")
var resumeFlag = flag.Bool("resume", false, "open the session picker to resume a session")
var resumeSessionFlag = flag.String("resume-session", "", "resume a specific session by name or ID")
var sessionIDFlag = flag.String("session-id", "", "resume a specific session by UUID")
var sessionFlag = flag.String("session", "", "set a display name for the claude session")
var commitFlag = flag.String("commit", "", "commit the current container as a new image (default: claude-code-sandbox-{dirname})")
var removeFlag = flag.Bool("rm", false, "remove the container for the current directory and exit")
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
	return imageRepo + ":" + *bundleFlag
}

// bundleDockerfile returns the embedded Dockerfile for the selected bundle.
func bundleDockerfile() ([]byte, error) {
	path := "dockerfiles/" + *bundleFlag + "/Dockerfile"
	data, err := dockerfiles.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("unknown bundle %q: no embedded %s", *bundleFlag, path)
	}
	return data, nil
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

// bundleSuffix qualifies per-directory names so bundles don't collide.
// The default bundle contributes nothing, so containers created before
// bundles existed keep their names.
func bundleSuffix() string {
	if *bundleFlag == defaultBundle {
		return ""
	}
	return "-" + *bundleFlag
}

func containerName() string {
	if *nameFlag != "" {
		return *nameFlag
	}
	return "claude-sandbox-" + cwdSlug() + bundleSuffix()
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

	if *removeFlag {
		if err := removeContainer(); err != nil {
			fmt.Fprintf(os.Stderr, "error: %v\n", err)
			os.Exit(1)
		}
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
		commitImage = commitImagePrefix + "-" + cwdSlug() + bundleSuffix()
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

func removeContainer() error {
	name := containerName()
	if !containerExists(name) {
		return fmt.Errorf("container %q does not exist", name)
	}

	if containerRunning(name) {
		fmt.Fprintf(os.Stderr, "Stopping container %q...\n", name)
		if err := exec.Command("docker", "stop", name).Run(); err != nil {
			return fmt.Errorf("stopping container: %w", err)
		}
	}

	fmt.Fprintf(os.Stderr, "Removing container %q...\n", name)
	cmd := exec.Command("docker", "rm", name)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("removing container: %w", err)
	}

	fmt.Fprintln(os.Stderr, "Done.")
	return nil
}

func ensureImage() error {
	img := effectiveImage()

	// Custom images must already exist — only pull or build known bundles.
	if *imageFlag != "" {
		if !imageExists(img) {
			return fmt.Errorf("image %q not found — build or pull it first", img)
		}
		warnArchMismatch(img)
		return nil
	}

	if imageExists(img) && !*pullFlag {
		warnArchMismatch(img)
		return nil
	}

	// Published bundles mirror dockerfiles/, so reject typos before hitting the registry.
	if _, err := bundleDockerfile(); err != nil {
		return err
	}

	// Prefer the prebuilt multi-arch image: pulling avoids compiling the Go
	// toolchain locally, which is where emulated builds tend to fall over.
	if err := pullImage(img); err == nil {
		warnArchMismatch(img)
		return nil
	} else if *pullFlag {
		return fmt.Errorf("pulling image: %w", err)
	} else {
		fmt.Fprintf(os.Stderr, "Could not pull %s (%v). Falling back to a local build.\n", img, err)
	}

	if err := buildImage(img); err != nil {
		return err
	}
	warnArchMismatch(img)
	return nil
}

func imageExists(img string) bool {
	check := exec.Command("docker", "image", "inspect", img)
	check.Stdout = nil
	check.Stderr = nil
	return check.Run() == nil
}

func pullImage(img string) error {
	fmt.Fprintf(os.Stderr, "Pulling sandbox image %s...\n", img)
	pull := exec.Command("docker", "pull", img)
	pull.Stdout = os.Stderr
	pull.Stderr = os.Stderr
	if err := pull.Run(); err != nil {
		return fmt.Errorf("docker pull %s: %w", img, err)
	}
	return nil
}

func buildImage(img string) error {
	df, err := bundleDockerfile()
	if err != nil {
		return err
	}

	fmt.Fprintln(os.Stderr, "Building sandbox image (one-time setup)...")

	tmpDir, err := os.MkdirTemp("", "claude-sandbox-*")
	if err != nil {
		return fmt.Errorf("creating temp dir: %w", err)
	}
	defer os.RemoveAll(tmpDir)

	if err := os.WriteFile(tmpDir+"/Dockerfile", df, 0644); err != nil {
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

// warnArchMismatch flags an image whose architecture differs from the host.
// Emulating amd64 on arm64 (Rosetta, qemu) corrupts the Go garbage collector,
// which crashes builds and Go tooling inside the container.
func warnArchMismatch(img string) {
	out, err := exec.Command("docker", "image", "inspect", "-f", "{{.Architecture}}", img).Output()
	if err != nil {
		return
	}
	imgArch := strings.TrimSpace(string(out))
	if imgArch == "" || imgArch == runtime.GOARCH {
		return
	}

	fmt.Fprintf(os.Stderr, "Warning: image %s is %s but this host is %s — it will run under emulation.\n", img, imgArch, runtime.GOARCH)
	fmt.Fprintln(os.Stderr, "Go tooling is unreliable under emulation. Unset DOCKER_DEFAULT_PLATFORM (or disable Rosetta")
	fmt.Fprintf(os.Stderr, "emulation in Docker Desktop) and re-run with -pull to get the native %s image.\n", runtime.GOARCH)
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
