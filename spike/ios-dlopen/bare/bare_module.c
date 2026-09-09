/* Bare module: the module-impl C ABI (logos_module_impl.h) with NO Qt and NO
 * logos-protocol linked. lp_protocol_version() is left undefined and must
 * resolve UPWARD into the app executable at dlopen time.
 *
 * Built twice (SPIKE_MODULE_TAG "A" and "B") into two frameworks exporting the
 * identical symbol names, for the RTLD_LOCAL isolation check (Level 3). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define EXPORT __attribute__((visibility("default")))

#ifndef SPIKE_MODULE_TAG
#define SPIKE_MODULE_TAG "untagged"
#endif

/* From logos_protocol.h; lives only in the app image. */
extern const char* lp_protocol_version(void);

typedef void (*logos_module_emit_cb)(const char*, const char*, void*);
typedef void (*logos_module_unload_done_cb)(void*);

static char* dup_str(const char* s)
{
    size_t n = strlen(s) + 1;
    char* out = (char*)malloc(n);
    if (out)
        memcpy(out, s, n);
    return out;
}

EXPORT char* logos_module_dispatch(const char* method, const char* args_json)
{
    (void)args_json;
    if (method && strcmp(method, "whoami") == 0) {
        char buf[512];
        snprintf(buf, sizeof buf,
                 "{\"module\":\"%s\",\"host_protocol\":\"%s\",\"dispatch_addr\":\"%p\"}",
                 SPIKE_MODULE_TAG, lp_protocol_version(), (void*)&logos_module_dispatch);
        return dup_str(buf);
    }
    return NULL;
}

EXPORT char* logos_module_get_methods(void)
{
    return dup_str("[{\"kind\":\"method\",\"name\":\"whoami\",\"params\":[],\"returns\":\"object\"}]");
}

EXPORT void logos_module_set_context(const char* module_path, const char* instance_id,
                                     const char* instance_persistence_path)
{
    (void)module_path; (void)instance_id; (void)instance_persistence_path;
}

EXPORT void logos_module_set_emit_callback(logos_module_emit_cb cb, void* user_data)
{
    (void)cb; (void)user_data;
}

EXPORT int logos_module_accept_token(const char* module_name, const char* token)
{
    (void)module_name; (void)token;
    return 0;
}

EXPORT int logos_module_accept_inbound_token(const char* caller, const char* token)
{
    (void)caller; (void)token;
    return 0;
}

EXPORT int logos_module_grant_host_services(const char* services_json)
{
    (void)services_json;
    return 0;
}

EXPORT void logos_module_set_unload_done_callback(logos_module_unload_done_cb cb, void* user_data)
{
    (void)cb; (void)user_data;
}

EXPORT int logos_module_about_to_unload(void) { return 0; }

EXPORT void logos_module_set_call_caller(const char* caller_json) { (void)caller_json; }

EXPORT const char* logos_module_get_protocol_version(void) { return "0.8.0+spike-" SPIKE_MODULE_TAG; }

EXPORT void logos_module_string_free(char* s) { free(s); }
