package main

import (
	_ "embed"
	"fmt"
	"os"
	"os/exec"
)

//go:embed Dockerfile
var dockerfile []byte

const imageName = "claude-code-sandbox"

func main() {
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

func run() error {
	cwd, err := os.Getwd()
	if err != nil {
		return fmt.Errorf("getting working directory: %w", err)
	}

	args := []string{"run", "--rm", "-i"}

	// Allocate a TTY only when stdin is a terminal
	if isTerminal(os.Stdin) {
		args = append(args, "-t")
	}

	args = append(args, "-v", cwd+":/workspace", "-w", "/workspace")

	if key := os.Getenv("ANTHROPIC_API_KEY"); key != "" {
		args = append(args, "-e", "ANTHROPIC_API_KEY="+key)
	}

	args = append(args, imageName, "claude", "--dangerously-skip-permissions", "--api-key", os.Getenv("ANTHROPIC_API_KEY"))
	args = append(args, os.Args[1:]...)

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
