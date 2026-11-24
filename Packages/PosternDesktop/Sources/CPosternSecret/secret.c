#include "CPosternSecret.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef __linux__
#include <libsecret/secret.h>

static const SecretSchema *postern_schema(void) {
    static const SecretSchema schema = {
        "ch.rubencatalao.postern", SECRET_SCHEMA_NONE,
        {
            { "item", SECRET_SCHEMA_ATTRIBUTE_STRING },
            { NULL, 0 },
        }
    };
    return &schema;
}

static int fail(GError *problem, char **error) {
    if (error) *error = strdup(problem ? problem->message : "The secret store did not answer.");
    if (problem) g_error_free(problem);
    return -1;
}

int postern_secret_store(const char *item, const char *value, char **error) {
    GError *problem = NULL;
    char label[160];
    snprintf(label, sizeof label, "Postern: %s", item);
    gboolean ok = secret_password_store_sync(postern_schema(), SECRET_COLLECTION_DEFAULT, label, value, NULL, &problem,
                                             "item", item, NULL);
    return ok ? 0 : fail(problem, error);
}

int postern_secret_lookup(const char *item, char **value, int *found, char **error) {
    GError *problem = NULL;
    gchar *secret = secret_password_lookup_sync(postern_schema(), NULL, &problem, "item", item, NULL);
    if (problem) return fail(problem, error);
    *found = secret != NULL;
    *value = secret ? strdup(secret) : NULL;
    if (secret) secret_password_free(secret);
    return 0;
}

int postern_secret_clear(const char *item, char **error) {
    GError *problem = NULL;
    secret_password_clear_sync(postern_schema(), NULL, &problem, "item", item, NULL);
    return problem ? fail(problem, error) : 0;
}

void postern_secret_free(char *text) { free(text); }

#else

int postern_secret_store(const char *item, const char *value, char **error) { (void)item; (void)value; if (error) *error = strdup("No Secret Service here."); return -1; }
int postern_secret_lookup(const char *item, char **value, int *found, char **error) { (void)item; *value = NULL; *found = 0; if (error) *error = strdup("No Secret Service here."); return -1; }
int postern_secret_clear(const char *item, char **error) { (void)item; if (error) *error = strdup("No Secret Service here."); return -1; }
void postern_secret_free(char *text) { free(text); }

#endif
