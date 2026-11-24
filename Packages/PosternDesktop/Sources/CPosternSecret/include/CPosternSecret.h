#ifndef CPOSTERN_SECRET_H
#define CPOSTERN_SECRET_H

// The Secret Service (GNOME Keyring, KWallet, KeePassXC) through libsecret, one item per key of Postern's vault.
// Each returns 0 on success; on failure it fills `error` (to free with postern_secret_free) and returns -1.
// `found` is 0 when lookup finds nothing.
int postern_secret_store(const char *item, const char *value, char **error);
int postern_secret_lookup(const char *item, char **value, int *found, char **error);
int postern_secret_clear(const char *item, char **error);
void postern_secret_free(char *text);

#endif
