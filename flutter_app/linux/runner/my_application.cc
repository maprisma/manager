#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#include <string.h>

#include "flutter/generated_plugin_registrant.h"

// Maprisma Manager's window: one instance (com.maprisma.Manager; a second start shows the
// first window), a header bar titled "Maprisma Manager", and the "maprisma-manager/window"
// channel: "titlebar" (dark or light and the header's colours, as the desktop's palette, also
// when the theme changes while the window is open) and, to Dart, "open" with a
// second start's words (`--page <page>`). `--toggle` (the bar icon) hides the window when it is
// shown (in front or not) and shows it otherwise: hidden, not closed, as a job may be running.
// Dart calls "hide" (Esc on the main page), "size" (the saved size) and "geometry".

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  FlMethodChannel* window_channel;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// The window, also while hidden (gtk_application_get_active_window skips none of them).
static GtkWindow* main_window(GApplication* application) {
  GList* windows = gtk_application_get_windows(GTK_APPLICATION(application));
  return windows == nullptr ? nullptr : GTK_WINDOW(windows->data);
}

// --- the window's size (Maprisma layout rule 5a) ---------------------------------

// The monitor the window is on, else the largest one (the window is not placed yet).
static GdkMonitor* size_monitor(GtkWindow* window) {
  GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(window));
  GdkWindow* gdk_window = gtk_widget_get_window(GTK_WIDGET(window));
  if (gdk_window != nullptr && gtk_widget_get_mapped(GTK_WIDGET(window))) {
    GdkMonitor* at = gdk_display_get_monitor_at_window(display, gdk_window);
    if (at != nullptr) return at;
  }
  GdkMonitor* best = nullptr;
  gint best_area = 0;
  for (gint i = 0; i < gdk_display_get_n_monitors(display); i++) {
    GdkMonitor* monitor = gdk_display_get_monitor(display, i);
    GdkRectangle area;
    gdk_monitor_get_workarea(monitor, &area);
    if (area.width * area.height > best_area) {
      best = monitor;
      best_area = area.width * area.height;
    }
  }
  return best;
}

// "size" [width, height]: the saved size, at most the screen's work area, at least 420 x 320.
static void resize_clamped(GtkWindow* window, gint width, gint height) {
  GdkMonitor* monitor = size_monitor(window);
  if (monitor != nullptr) {
    GdkRectangle area;
    gdk_monitor_get_workarea(monitor, &area);
    if (area.width > 0) width = MIN(width, area.width);
    if (area.height > 0) height = MIN(height, area.height);
  }
  gtk_window_resize(window, MAX(width, 420), MAX(height, 320));
}

// "geometry": {width, height, free}; free = shown and neither maximized, fullscreen nor tiled
// (only a size the user gave it is saved).
static FlValue* window_geometry(GtkWindow* window) {
  gint width = 0, height = 0;
  gtk_window_get_size(window, &width, &height);
  GdkWindow* gdk_window = gtk_widget_get_window(GTK_WIDGET(window));
  GdkWindowState state = gdk_window != nullptr ? gdk_window_get_state(gdk_window) : (GdkWindowState)0;
  // Hyprland reports every window as maximised and tiled, floating ones too: there only full
  // screen means the size isn't the user's (the maprisma-app rule).
  const gchar* hypr = g_getenv("HYPRLAND_INSTANCE_SIGNATURE");
  GdkWindowState busy = (GdkWindowState)(GDK_WINDOW_STATE_FULLSCREEN |
      ((hypr != nullptr && hypr[0] != '\0') ? 0 : (GDK_WINDOW_STATE_MAXIMIZED | GDK_WINDOW_STATE_TILED)));
  gboolean free = gtk_widget_get_visible(GTK_WIDGET(window)) && (state & busy) == 0;
  FlValue* map = fl_value_new_map();
  fl_value_set_string_take(map, "width", fl_value_new_int(width));
  fl_value_set_string_take(map, "height", fl_value_new_int(height));
  fl_value_set_string_take(map, "free", fl_value_new_bool(free));
  return map;
}

// --- the header bar's colours ----------------------------------------------------

// "#rrggbb" or null.
static const gchar* hex_arg(FlValue* map, const gchar* key) {
  FlValue* v = fl_value_lookup_string(map, key);
  if (v == nullptr || fl_value_get_type(v) != FL_VALUE_TYPE_STRING) return nullptr;
  const gchar* s = fl_value_get_string(v);
  if (strlen(s) != 7 || s[0] != '#') return nullptr;
  for (int i = 1; i < 7; i++) {
    if (!g_ascii_isxdigit(s[i])) return nullptr;
  }
  return s;
}

// GTK draws the header bar with the GTK theme's colours, read once at start (colors.css that
// Maprisma Theme writes): a theme changed while the window is open would leave the old
// colours in it. So the header takes the palette's background and text from Dart, which
// re-reads the look while running, through a CSS provider of its own.
static void set_header_colors(const gchar* bg, const gchar* fg, const gchar* border) {
  static GtkCssProvider* provider = nullptr;
  GdkScreen* screen = gdk_screen_get_default();
  if (screen == nullptr) return;
  if (provider == nullptr) {
    provider = gtk_css_provider_new();
    gtk_style_context_add_provider_for_screen(screen, GTK_STYLE_PROVIDER(provider),
                                              GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
  }
  g_autofree gchar* css = g_strdup_printf(
      "headerbar, headerbar:backdrop, .titlebar, .titlebar:backdrop {"
      " background: %s; background-image: none; color: %s;"
      " border-color: %s; box-shadow: none; }"
      " headerbar .title, headerbar button, headerbar button image {"
      " color: %s; }"
      " headerbar:backdrop .title, headerbar:backdrop button { color: alpha(%s, 0.7); }",
      bg, fg, border, fg, fg);
  gtk_css_provider_load_from_data(provider, css, -1, nullptr);
}

static void window_call_cb(FlMethodChannel* channel, FlMethodCall* call,
                           gpointer user_data) {
  g_autoptr(FlMethodResponse) response = nullptr;
  const gchar* name = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  if (g_strcmp0(name, "titlebar") == 0) {
    if (args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_BOOL) {
      g_object_set(gtk_settings_get_default(), "gtk-application-prefer-dark-theme",
                   fl_value_get_bool(args), nullptr);
    } else if (args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
      // {dark, background, foreground, border}: light/dark and the header's own colours.
      FlValue* dark = fl_value_lookup_string(args, "dark");
      if (dark != nullptr && fl_value_get_type(dark) == FL_VALUE_TYPE_BOOL) {
        g_object_set(gtk_settings_get_default(), "gtk-application-prefer-dark-theme",
                     fl_value_get_bool(dark), nullptr);
      }
      const gchar* bg = hex_arg(args, "background");
      const gchar* fg = hex_arg(args, "foreground");
      const gchar* border = hex_arg(args, "border");
      if (bg != nullptr && fg != nullptr) set_header_colors(bg, fg, border != nullptr ? border : bg);
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(name, "hide") == 0) {
    // Esc on the main page: hidden as by --toggle; running jobs go on.
    GtkWindow* window = main_window(g_application_get_default());
    if (window != nullptr) gtk_widget_hide(GTK_WIDGET(window));
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(name, "size") == 0) {
    GtkWindow* window = main_window(g_application_get_default());
    if (window != nullptr && args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_LIST &&
        fl_value_get_length(args) == 2 &&
        fl_value_get_type(fl_value_get_list_value(args, 0)) == FL_VALUE_TYPE_INT &&
        fl_value_get_type(fl_value_get_list_value(args, 1)) == FL_VALUE_TYPE_INT) {
      resize_clamped(window, (gint)fl_value_get_int(fl_value_get_list_value(args, 0)),
                     (gint)fl_value_get_int(fl_value_get_list_value(args, 1)));
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(name, "geometry") == 0) {
    GtkWindow* window = main_window(g_application_get_default());
    g_autoptr(FlValue) geometry = window != nullptr ? window_geometry(window) : fl_value_new_null();
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(geometry));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(call, response, nullptr);
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* existing = main_window(application);
  if (existing != nullptr) {
    gtk_widget_show(GTK_WIDGET(existing));
    gtk_window_present(existing);
    return;
  }
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
  gtk_widget_show(GTK_WIDGET(header_bar));
  gtk_header_bar_set_title(header_bar, "Maprisma Manager");
  gtk_header_bar_set_show_close_button(header_bar, TRUE);
  gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  gtk_window_set_title(window, "Maprisma Manager");
  gtk_window_set_default_size(window, 900, 680);
  gtk_window_set_icon_name(window, APPLICATION_ID);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->window_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)), "maprisma-manager/window",
      FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->window_channel, window_call_cb, self,
                                            nullptr);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name; --toggle is the runner's own.
  gboolean toggle = FALSE;
  g_autoptr(GPtrArray) words = g_ptr_array_new_with_free_func(g_free);
  for (gchar** arg = *arguments + 1; *arg != nullptr; arg++) {
    if (g_strcmp0(*arg, "--toggle") == 0) {
      toggle = TRUE;
    } else {
      g_ptr_array_add(words, g_strdup(*arg));
    }
  }
  g_ptr_array_add(words, nullptr);
  self->dart_entrypoint_arguments = g_strdupv((gchar**)words->pdata);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  if (g_application_get_is_remote(application)) {
    // A second start: the first one acts.
    if (toggle) {
      g_action_group_activate_action(G_ACTION_GROUP(application), "toggle", nullptr);
    } else if (g_strv_length(self->dart_entrypoint_arguments) > 0) {
      g_action_group_activate_action(G_ACTION_GROUP(application), "open",
                                     g_variant_new_strv(self->dart_entrypoint_arguments, -1));
    } else {
      g_application_activate(application);
    }
    *exit_status = 0;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// --toggle (the bar icon, the applet, Maprisma Shell): a shown window hides, in front or not (a
// click on the bar may take the focus first); a hidden or closed one is shown and brought up.
static void toggle_activated(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
  GApplication* application = G_APPLICATION(user_data);
  GtkWindow* window = main_window(application);
  if (window != nullptr && gtk_widget_get_visible(GTK_WIDGET(window))) {
    gtk_widget_hide(GTK_WIDGET(window));
    return;
  }
  g_application_activate(application);
}

// A second start's words (--page <page>) go to Dart; the window comes up.
static void open_activated(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  g_application_activate(G_APPLICATION(self));
  if (self->window_channel == nullptr || parameter == nullptr) return;
  g_autoptr(FlValue) list = fl_value_new_list();
  gsize n = 0;
  g_autofree const gchar** strv = g_variant_get_strv(parameter, &n);
  for (gsize i = 0; i < n; i++) fl_value_append_take(list, fl_value_new_string(strv[i]));
  fl_method_channel_invoke_method(self->window_channel, "open", list, nullptr, nullptr, nullptr);
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
  g_autoptr(GSimpleAction) toggle = g_simple_action_new("toggle", nullptr);
  g_signal_connect(toggle, "activate", G_CALLBACK(toggle_activated), application);
  g_action_map_add_action(G_ACTION_MAP(application), G_ACTION(toggle));
  g_autoptr(GSimpleAction) open = g_simple_action_new("open", G_VARIANT_TYPE_STRING_ARRAY);
  g_signal_connect(open, "activate", G_CALLBACK(open_activated), application);
  g_action_map_add_action(G_ACTION_MAP(application), G_ACTION(open));
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_object(&self->window_channel);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_DEFAULT_FLAGS, nullptr));
}
