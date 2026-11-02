package build

/// BEGIN build.odin

/*
Lightweight mini library for Odin build system.
*/

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"

tprintf :: fmt.tprintf

/*
Check os.error and log error
*/
os_error :: proc(err: os.Error, ctx: any = nil, loc := #caller_location) -> bool {
	if err != nil {
		if ctx == nil {
			log.error(os.error_string(err), location = loc)
		} else {
			log.error(ctx, os.error_string(err), location = loc)
		}
		return false
	}
	return true
}

/*
Prints error for you to return a bool instead
Convenience to run multiple processes
*/
start :: proc(
	commands: []string,
	stdin := os.stdin,
	stderr := os.stderr,
	stdout := os.stdout,
	working_dir := "",
	loc := #caller_location,
) -> (
	p: os.Process,
	ok: bool,
) {
	err: os.Error
	p, err = os.process_start(
		{
			stderr = stderr,
			stdout = stdout,
			stdin = stdin,
			command = commands,
			working_dir = working_dir,
		},
	)
	os_error(err, commands, loc) or_return
	return p, true
}

/*
Prints error for you to return a bool instead
*/
wait :: proc(process: os.Process, loc := #caller_location) -> bool {
	state, err := os.process_wait(process)
	os_error(err, loc = loc) or_return
	return state.exit_code == 0
}

sh :: proc {
	sh_static,
	sh_dynamic,
}

/*
Executes a command
*/
sh_static :: proc(commands: []string, working_dir := "", loc := #caller_location) -> bool {
	fmt.print("| ")
	for cmd in commands {
		fmt.print(cmd)
		fmt.print(' ')
	}
	fmt.print('\n')
	process := start(commands, working_dir = working_dir, loc = loc) or_return
	return wait(process, loc = loc)
}

/*
Convenient wrapper to sh_static.
Use case: You can define reusable flags/args
*/
sh_dynamic :: proc(args: ..union {
		[]string,
		string,
	}, working_dir := "", loc := #caller_location) -> bool {
	cmds := make([dynamic]string, allocator = context.temp_allocator)
	for flags in args {
		switch v in flags {
		case []string:
			length := len(cmds)
			resize(&cmds, len(cmds) + len(v))
			copy(cmds[length:], v)
		case string:
			append(&cmds, v)
		}

	}
	return sh(cmds[:], working_dir, loc = loc)
}

/*
Lightweight RTTI flag parser
*/
parse_flags :: proc(opts: []struct {
		name: string,
		var:  any,
	}, help: string, args := os.args) {
	is_opt :: proc(arg: string) -> bool {return !(arg[0] == '-')}
	i: int

	for arg in args {
		if len(arg) < 2 do continue
		switch arg[1:] {
		case "h", "help":
			fmt.println(help)
			os.exit(0)
		}
	}

	for ; i < len(args); i += 1 {
		arg := args[i]

		for &opt in opts {
			if len(arg) < 2 do continue
			if arg[1:] != opt.name do continue

			switch v in opt.var {
			case ^bool:
				v^ = !v^
			case ^string:
				if i + 1 >= len(args) do return
				value := args[i + 1]
				is_opt(value) or_continue
				v^ = value
			}
			break
		}
	}
	return
}
/// END build.odin

/*
Symlink
*/
ln :: proc(src, dst: string, loc := #caller_location) -> bool {
	if os.exists(dst) do return true
	absolute_src, err := os.get_absolute_path(src, context.temp_allocator)
	os_error(err, src, loc = loc)
	os.make_directory_all(os.dir(dst))
	err = os.symlink(absolute_src, dst)
	if err != nil {
		log.error("%s -> %s:", src, dst, os.error_string(err), location = loc)
		return false
	}
	return true
}

SHARED :: "./shared"
/*
Clone a git repository
*/
clone :: proc(repo: string, loc := #caller_location) -> bool {
	path := tprintf("%s/%s-git", SHARED, os.base(repo))
	if os.exists(path) do return true
	return sh({"git", "clone", "--depth", "1", repo, path}, loc = loc)
}

HELP :: `Usage: (debug,release) [option]
Options:
  -nobuild   | Only get dependencies
	-force     | Force rebuild
	-global    | Use global dependencies`

main :: proc() {
	context.logger = log.create_console_logger(
		opt = {.Level, .Terminal_Color, .Short_File_Path, .Line},
	)
	defer log.destroy_console_logger(context.logger)

	if len(os.args) < 2 {
		log.error(
			"Compilation mode is undefined. Please run either\n" +
			"  odin run . -- debug\n" +
			"  odin run . -- release",
		)
		return
	}

	mode: string = os.args[1]
	nobuild, force, global: bool
	parse_flags({{"global", &global}, {"nobuild", &nobuild}, {"force", &force}}, HELP, os.args[2:])

	os.make_directory("bin")

	if !global {
		clone("https://github.com/aocoronel/odd")
		clone("https://github.com/aocoronel/odin-sqlite3")
		ln("./shared/odd-git/odd/", "./shared/odd")
		ln("./shared/odin-sqlite3-git/sqlite3/", "./shared/sqlite3")
	}

	if nobuild do return

	source_code :: "./src"
	deps := "" if global else "-collection:shared=shared/"

	ODIN_FLAGS :: []string{"-show-timings", "-custom-attribute:command", "-out:bin/tp"}

	switch mode {
	case "debug":
		sh("odin", "build", source_code, ODIN_FLAGS, deps, "-debug")
	case "release":
		sh("odin", "build", source_code, ODIN_FLAGS, deps, "-o:speed")
	case:
		log.errorf("Invalid mode: %q", mode)
	}
}
