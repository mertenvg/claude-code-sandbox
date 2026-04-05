package main

import (
	_ "embed"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strings"
)

//go:embed Dockerfile
var dockerfile []byte

const imageName = "claude-code-sandbox"

var nonAlphanumeric = regexp.MustCompile(`[^a-zA-Z0-9]+`)

var nameFlag = flag.String("name", "", "override the container name")
var debugFlag = flag.Bool("debug", false, "start the container as root with /bin/bash instead of claude")

func containerName() string {
	if *nameFlag != "" {
		return *nameFlag
	}
	cwd, err := os.Getwd()
	if err != nil {
		cwd = "default"
	}
	slug := strings.ToLower(nonAlphanumeric.ReplaceAllString(cwd, "-"))
	slug = strings.Trim(slug, "-")
	return "claude-sandbox-" + slug
}

func main() {
	flag.Parse()

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

func ensureImage() error {
	check := exec.Command("docker", "image", "inspect", imageName)
	check.Stdout = nil
	check.Stderr = nil
	if check.Run() == nil {
		return nil
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

	build := exec.Command("docker", "build", "-t", imageName, tmpDir)
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

	if *debugFlag {
		if containerRunning(name) {
			fmt.Fprintln(os.Stderr, "Attaching debug shell to running container...")
			return execContainer(name)
		}
		if containerExists(name) {
			fmt.Fprintln(os.Stderr, "Starting stopped container and attaching debug shell...")
			if err := startContainerDetached(name); err != nil {
				return fmt.Errorf("starting container: %w", err)
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
	cmd := exec.Command("docker", "start", "-a", "-i", name)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func startContainerDetached(name string) error {
	return exec.Command("docker", "start", name).Run()
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

	args := []string{"run", "-i", "--name", name}

	// Allocate a TTY only when stdin is a terminal
	if isTerminal(os.Stdin) {
		args = append(args, "-t")
	}

	args = append(args, "-v", cwd+":/workspace", "-w", "/workspace")

	if key := os.Getenv("ANTHROPIC_API_KEY"); key != "" {
		args = append(args, "-e", "ANTHROPIC_API_KEY="+key)
	}

	if *debugFlag {
		args = append(args, "-u", "0")
		args = append(args, imageName, "/bin/bash")
	} else {
		args = append(args, imageName, "claude", "--dangerously-skip-permissions")
	}
	args = append(args, flag.Args()...)

	cmd := exec.Command("docker", args...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func isTerminal(f *os.File) bool {
	fi, err := f.Stat()
	if err != nil {
		return false
	}
	return fi.Mode()&os.ModeCharDevice != 0
}
