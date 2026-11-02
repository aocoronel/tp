package main

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "shared:odd/debug"
import "shared:odd/flags"
import sqlite "shared:sqlite3"

Directory :: struct {
	path:  string,
	count: int,
	mtime: int,
}

Error :: union {
	bool,
	os.Error,
	runtime.Allocator_Error,
}

main :: proc() {
	code: int
	{
		debug.register_backtrace()
		debug.short_level_header()
		context.logger = log.create_console_logger(opt = debug.LOGGER_OPT)
		defer log.destroy_console_logger(context.logger)

		error := _main()
		switch err in error {
		case bool:
			code = cast(int)!err
		case os.Error:
			log.error(os.error_string(err))
			code = 1
		case runtime.Allocator_Error:
			log.error(os.error_string(err))
			code = 1
		}
	}
	if code > 0 {
		os.exit(code)
	}
	return
}

_main :: proc() -> Error {
	context.allocator = context.temp_allocator

	db: ^sqlite.SQLite3
	defer sqlite.close(db) // ok, if db is nil

	dir: [dynamic]string
	database: cstring
	prune, list, query: bool

	opts := []flags.Option {
		{"d,database", "Path to database", &database, nil},
		{"prune", "Remove all invalid entries", &prune, nil},
		{"list", "List all entries", &list, nil},
		{"query", "Return matches", &query, nil},
	}

	m, ok := flags.init(opts)
	defer delete(m)

	has_err: bool
	for flags.has_args_left() {
		err := flags.parse(m, opts)
		switch err {
		case .Ok:
			continue
		case .Dash_Dash:
		// rest := get_args()[optind:]
		case .Help_Request:
			fmt.eprintln("Usage:", flags.get_args()[0], "[option]", "dir..")
			fmt.eprintln("Options:")
			flags.usage(opts)
			return true
		case .Not_Opt:
			append(&dir, flags.optopt)
		case .Error:
			has_err = true
		}
	}
	if has_err do return false

	if len(database) == 0 {
		_db, found := os.lookup_env("TP_DATABASE", context.allocator)
		if found {
			database = strings.clone_to_cstring(_db, context.allocator) or_return
		} else {
			dir := os.user_cache_dir(context.allocator) or_return
			database = fmt.caprintf("%s/tp.db", dir)
		}
	}

	{
		// Setup database
		status := sqlite.open(database, &db)
		if status != nil {
			sql_error(db)
			return false
		}
		execute(db, TABLE) or_return
	}

	if list do return list_entries(db)
	if prune do return prune_entries(db)

	// User didn't provided any path. Fallback to $HOME
	if len(dir) == 0 {
		home := os.user_home_dir(context.allocator) or_return
		fmt.println(home)
		return true
	}

	// If input is a valid directory, use it
	if len(dir) == 1 {
		isdir := os.is_dir(dir[0])
		if isdir {
			abs_dir := insert(db, dir[0]) or_return
			fmt.println(abs_dir)
			return true
		}
	}

	if query {
		stmt := find_relaxed_entries(db, dir[:]) or_return
		defer sqlite.finalize(stmt)
		for {
			row, status := sqlite.execute(db, stmt, Directory)
			if status != nil {
				if status == .Done do break
				sql_error(db)
				return false
			}
			fmt.println(row.path)
		}
		return true
	}

	stmt := find_entries(db, dir[:]) or_return
	defer sqlite.finalize(stmt)

	cwd := os.get_working_directory(context.allocator) or_return

	for {
		row, status := sqlite.execute(db, stmt, Directory)
		if status != nil {
			if status == .Done do break
			sql_error(db)
			return false
		}
		// Remove invalid entries
		if !os.exists(row.path) {
			remove(db, row.path) or_return
			continue
		}
		// Suggest a different dir, if it's CWD
		if row.path == cwd do continue
		execute(db, INSERT, row.path) or_return
		fmt.println(row.path)
		return true
	}

	log.error("no match")
	return false
}

remove :: proc(db: ^sqlite.SQLite3, path: string) -> bool {
	return execute(db, DELETE, path)
}

insert :: proc(db: ^sqlite.SQLite3, dir: string) -> (abs_dir: string, ok: bool) {
	err: os.Error
	fi: os.File_Info

	fi, err = os.stat(dir, context.allocator)
	if err != nil {
		if err == os.General_Error.Not_Exist {
			log.errorf("%s: %s", dir, "directory does not exists")
		} else {
			log.errorf("%s: %s", dir, os.error_string(err))
		}
		return "", false
	}

	#partial switch fi.type {
	case .Directory:
	case:
		log.errorf("%s: not a directory", dir)
		return "", false
	}

	abs_dir, err = os.get_absolute_path(dir, context.allocator)
	if err != nil {
		log.errorf("%s: %s", dir, os.error_string(err))
		return "", false
	}

	execute(db, INSERT, abs_dir) or_return

	return abs_dir, true
}

// Taken from core:os, but also adds the sep to the first element
join :: proc(
	a: []string,
	sep: string,
	allocator := context.allocator,
	loc := #caller_location,
) -> (
	res: string,
	err: runtime.Allocator_Error,
) #no_bounds_check #optional_allocator_error {
	if len(a) == 0 {
		return "", nil
	}

	n := len(sep) * len(a)
	for s in a {
		n += len(s)
	}

	b := make([]byte, n, allocator, loc) or_return
	i: int
	for s in a {
		i += copy(b[i:], sep)
		i += copy(b[i:], s)
	}
	return string(b), nil
}

find_entries :: proc(db: ^sqlite.SQLite3, args: []string) -> (^sqlite.Stmt, bool) {
	match, err := join(args, "%", context.allocator)
	if err != nil {
		log.errorf("%s: %s", args, os.error_string(err))
		return nil, false
	}

	stmt, status := sqlite.prepare(db, FIND, match, match)
	if status != nil {
		log.errorf("%v: %s", status, sqlite.errmsg(db))
		return nil, false
	}

	return stmt, true
}

find_relaxed_entries :: proc(db: ^sqlite.SQLite3, args: []string) -> (^sqlite.Stmt, bool) {
	match, err := join(args, "%", context.allocator)
	if err != nil {
		log.errorf("%s: %s", args, os.error_string(err))
		return nil, false
	}

	stmt, status := sqlite.prepare(db, FIND_RELAXED, match)
	if status != nil {
		log.errorf("%v: %s", status, sqlite.errmsg(db))
		return nil, false
	}

	return stmt, true
}

list_entries :: proc(db: ^sqlite.SQLite3) -> bool {
	stmt, status := sqlite.prepare(db, "SELECT * FROM directory;")
	defer sqlite.finalize(stmt)
	if status != nil {
		sql_error(db)
		return false
	}
	rows: [dynamic]sqlite.SQLite_Types
	defer delete(rows)
	for {
		rows, status = sqlite.execute(db, stmt, rows)
		if status != nil {
			if status == .Done do break
			sql_error(db)
			return false
		}
		fmt.println(rows[0].(cstring))
	}
	return true
}

prune_entries :: proc(db: ^sqlite.SQLite3) -> bool {
	stmt, status := sqlite.prepare(db, "SELECT * FROM directory;")
	defer sqlite.finalize(stmt)
	if status != nil {
		log.errorf("%v: %s", status, sqlite.errmsg(db))
		return false
	}
	for {
		row, status := sqlite.execute(db, stmt, Directory)
		if status != nil {
			if status == .Done do break
			log.errorf("%v: %s", status, sqlite.errmsg(db))
			return false
		}
		if !os.exists(row.path) {
			remove(db, row.path)
		}
	}
	return true
}

sql_error :: #force_inline proc(db: ^sqlite.SQLite3, loc := #caller_location) {
	log.errorf("%s", sqlite.errmsg(db), location = loc)
}

execute :: proc(db: ^sqlite.SQLite3, sql: string, args: ..any, loc := #caller_location) -> bool {
	stmt, status := sqlite.prepare(db, sql, ..args, loc = loc)
	defer sqlite.finalize(stmt)
	if status != nil {
		sql_error(db, loc)
		fmt.print(sqlite.shell_error_context(db, sql))
		return false
	}
	status = sqlite.execute(stmt)
	if status != .Done {
		sql_error(db, loc)
		return false
	}
	return true
}
