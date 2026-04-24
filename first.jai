//
// usage:
// jai first.jai            -> debug build    (build/betterss_debug.exe)
// jai first.jai - release  -> release build  (build/betterss.exe)
//

#run build();

build :: () {
    set_build_options_dc(.{do_output = false});

    is_release := false;
    for get_build_options().compile_time_command_line {
        if it == {
            case "release"; is_release = true;
            case "debug";   is_release = false;
            case;           compiler_report(tprint("Unknown argument: '%'. Valid: release, debug.\n", it));
        }
    }

    w := compiler_create_workspace(ifx is_release then "BetterSS Release" else "BetterSS Debug");
    if !w compiler_report("Workspace creation failed.\n");

    options := get_build_options(w);
    options.output_path            = "build/";
    options.output_executable_name = ifx is_release then "betterss" else "betterss_debug";

    if is_release {
        set_optimization(*options, .VERY_OPTIMIZED, preserve_debug_info = false);
        options.stack_trace           = false;
        options.backtrace_on_crash    = .OFF;
        options.dead_code_elimination = .ALL;
    } else {
        set_optimization(*options, .DEBUG);
    }

    // dont show a console window when run from explorer
    options.additional_linker_arguments = .["/SUBSYSTEM:WINDOWS", "/ENTRY:main"];

    set_build_options(options, w);

    make_directory_if_it_does_not_exist("build", recursive = true);

    // single source of truth for build config
    config := tprint(#string DONE
BUILD_GIT_HASH :: "%";
IS_RELEASE     :: %;
DONE, get_git_hash(), ifx is_release then "true" else "false");
    add_build_string(config, w);

    add_build_file(tprint("%main.jai", #filepath), w);
}

get_git_hash :: () -> string {
    result, out := run_command("git", "describe", "--always", "--dirty", capture_and_return_output = true);
    if result.exit_code != 0 return "unknown";
    s := trim(out);
    if s.count == 0 return "unknown";
    return copy_string(s);
}

#import "Basic";
#import "Compiler";
#import "File";
#import "Process";
#import "String";
