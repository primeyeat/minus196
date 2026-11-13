/*
 * -196's start-up hook for the Wine engine.
 *
 * The CodeWeavers Wine source loads "<ntdll dir>/cxcompatdb.so" with dlopen() at the end of
 * process start-up and exports prepend_dll_path() from ntdll.so for it to call. This file is
 * an independent implementation of that hook: all it does is put the folders listed in
 * MINUS196_DLL_PATH (colon separated, first = highest priority) in front of Wine's builtin DLL
 * search path, so a graphics backend's d3d11.dll and friends are found before Wine's own.
 * Which folders to list is decided by the wrapper before launch.
 *
 * The environment is inherited by every child process, but some programs must keep Wine's own
 * Direct3D whatever the bottle uses (the Steam client's embedded browser never finishes
 * starting on DXVK, for one). MINUS196_BUILTIN_EXES lists such programs by file name (colon
 * separated, lower case); in those processes the folders are not added.
 */
#include <dlfcn.h>
#include <crt_externs.h>
#include <ctype.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef void (*prepend_fn)(const char *path);

static prepend_fn find_prepend(void)
{
    uint32_t i, count = _dyld_image_count();
    for (i = 0; i < count; i++)
    {
        const char *name = _dyld_get_image_name(i);
        size_t len = name ? strlen(name) : 0;
        if (len >= 9 && !strcmp(name + len - 9, "/ntdll.so"))
        {
            void *handle = dlopen(name, RTLD_LAZY | RTLD_NOLOAD);
            if (handle) return (prepend_fn)dlsym(handle, "prepend_dll_path");
        }
    }
    return NULL;
}

/* True if this process's command line names one of the programs in the list. */
static int is_listed_program(const char *list)
{
    char cmdline[4096], *names, *name;
    char **argv = *_NSGetArgv();
    int argc = *_NSGetArgc(), found = 0;
    size_t pos = 0;

    if (!list || !*list || !argv) return 0;
    for (int i = 0; i < argc && argv[i]; i++)
        for (const char *p = argv[i]; ; p++)
        {
            if (pos + 2 >= sizeof(cmdline)) goto done;
            if (!*p) { cmdline[pos++] = ' '; break; }
            cmdline[pos++] = tolower((unsigned char)*p);
        }
done:
    cmdline[pos] = 0;
    if (!(names = strdup(list))) return 0;
    for (name = strtok(names, ":"); name && !found; name = strtok(NULL, ":"))
    {
        size_t len = strlen(name);
        for (char *hit = cmdline; len && (hit = strstr(hit, name)); hit++)
        {
            char before = hit == cmdline ? '/' : hit[-1], after = hit[len];
            if ((before == '/' || before == '\\' || before == '"' || before == ' ') &&
                (after == 0 || after == ' ' || after == '"')) { found = 1; break; }
        }
    }
    free(names);
    return found;
}

__attribute__((constructor))
static void minus196_compat_init(void)
{
    const char *env = getenv("MINUS196_DLL_PATH");
    char *copy, *entries[32];
    int n = 0;
    prepend_fn prepend;

    if (!env || !*env) return;
    if (is_listed_program(getenv("MINUS196_BUILTIN_EXES")))
    {
        /* These are launchers, not games: keep Apple's performance overlay (switched on for a
         * bottle with env.MTL_HUD_ENABLED=1) off their windows. Metal reads the variable when it
         * is first used, which is after this runs. Children get their own check. */
        if (getenv("MTL_HUD_ENABLED")) { setenv("MINUS196_HUD", "1", 1); unsetenv("MTL_HUD_ENABLED"); }
        return;
    }
    /* A game started by such a launcher: give it back the overlay the launcher had hidden. */
    if (getenv("MINUS196_HUD") && !getenv("MTL_HUD_ENABLED")) setenv("MTL_HUD_ENABLED", "1", 1);
    if (!(prepend = find_prepend()))
    {
        fprintf(stderr, "minus196: this engine has no prepend_dll_path(); MINUS196_DLL_PATH ignored\n");
        return;
    }
    /* The strings are kept by ntdll for the life of the process, so they are never freed. */
    if (!(copy = strdup(env))) return;
    /* Absolute folders only: a relative one would depend on the working directory. */
    for (char *p = strtok(copy, ":"); p && n < 32; p = strtok(NULL, ":")) if (*p == '/') entries[n++] = p;
    /* Each call puts its folder first, so add them last to first. */
    while (n--) prepend(entries[n]);
}
