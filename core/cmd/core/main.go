//go:build !android

package main

import (
	"core"
	"fmt"
	"os"
	"runtime"
)

func main() {
	args := os.Args
	if len(args) <= 1 {
		fmt.Fprintln(os.Stderr, "Arguments error")
		os.Exit(1)
	}
	if runtime.GOOS == "darwin" && args[1] == "--authorize-macos-tun" {
		if len(args) != 2 {
			fmt.Fprintln(os.Stdout, "invalid arguments")
			os.Exit(1)
		}
		if err := authorizeMacOSTun(); err != nil {
			fmt.Fprintln(os.Stdout, err)
			os.Exit(1)
		}
		fmt.Fprintln(os.Stdout, "ready")
		return
	}
	go core.ExitOnTermination()
	core.StartServer(args[1])
}

func authorizeMacOSTun() error {
	if os.Geteuid() != 0 {
		return os.ErrPermission
	}
	path, err := os.Executable()
	if err != nil {
		return err
	}
	before, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if !before.Mode().IsRegular() || before.Mode().Perm()&0022 != 0 {
		return os.ErrPermission
	}
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()
	current, err := file.Stat()
	if err != nil {
		return err
	}
	if !os.SameFile(before, current) {
		return os.ErrPermission
	}
	const adminGroup = 80 // macOS's built-in admin group.
	if err := file.Chown(0, adminGroup); err != nil {
		return err
	}
	return file.Chmod(os.ModeSetuid | 0750)
}
