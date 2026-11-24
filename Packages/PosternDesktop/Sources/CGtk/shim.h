#ifdef __linux__
#include <adwaita.h>
#include <gtk/gtk.h>

// Signals take a C callback; Swift closures go through these, with a boxed context freed by GLib.
static inline gulong postern_connect(gpointer instance, const char *signal, GCallback handler, gpointer data, GClosureNotify destroy) {
    return g_signal_connect_data(instance, signal, handler, data, destroy, (GConnectFlags)0);
}
#endif
