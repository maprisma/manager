// Shared by the Maprisma Flutter runners (Settings, Launcher, Theme, Playground, Mail): keep the
// copies byte-identical.
#ifndef MAPRISMA_DESKTOP_SESSION_H_
#define MAPRISMA_DESKTOP_SESSION_H_

#include <glib.h>
#include <string.h>

// Whether this is a Hyprland session. XDG_CURRENT_DESKTOP decides when it is set; only without it
// does HYPRLAND_INSTANCE_SIGNATURE count, and only when that Hyprland's socket is there
// ($XDG_RUNTIME_DIR/hypr/<signature>/.socket.sock): after a Hyprland session the variable stays in
// the systemd user environment, so COSMIC and KDE apps see a stale one.
static inline gboolean maprisma_on_hyprland(void) {
  const gchar* current = g_getenv("XDG_CURRENT_DESKTOP");
  if (current != NULL && current[0] != '\0') {
    gchar** names = g_strsplit(current, ":", -1);
    gboolean found = FALSE;
    for (gchar** n = names; *n != NULL; n++) {
      if (g_ascii_strcasecmp(*n, "Hyprland") == 0) found = TRUE;
    }
    g_strfreev(names);
    return found;
  }
  const gchar* signature = g_getenv("HYPRLAND_INSTANCE_SIGNATURE");
  const gchar* runtime = g_getenv("XDG_RUNTIME_DIR");
  if (signature == NULL || signature[0] == '\0' || signature[0] == '.' || strchr(signature, '/') != NULL ||
      runtime == NULL || runtime[0] != '/') {
    return FALSE;
  }
  gchar* socket = g_build_filename(runtime, "hypr", signature, ".socket.sock", NULL);
  gboolean live = g_file_test(socket, G_FILE_TEST_EXISTS);
  g_free(socket);
  return live;
}

#endif  // MAPRISMA_DESKTOP_SESSION_H_
