#if os(Linux)
import CGtk
import Foundation

// A thin layer over GTK 4 and libadwaita's C API: widgets are raw pointers, cast to the type each call expects.
// Everything here runs on GTK's main thread; work from other threads comes back through `onMain`.

typealias W = UnsafeMutableRawPointer

/// The pointer type a GTK call expects, typed (`GtkBox *`) or opaque (a final libadwaita type): both are one address.
@inline(__always) func cast<P>(_ widget: W?) -> P? { widget.map { unsafeBitCast($0, to: P.self) } }
@inline(__always) func opaque<P>(_ widget: W?) -> P? { cast(widget) }
@inline(__always) func raw<T>(_ pointer: UnsafeMutablePointer<T>?) -> W? { pointer.map { W($0) } }
@inline(__always) func raw(_ pointer: OpaquePointer?) -> W? { pointer.map { W($0) } }

// MARK: Closures for signals and idle callbacks

final class Callback {
    let run: (W?, W?) -> Void
    init(_ run: @escaping (W?, W?) -> Void) { self.run = run }
}

private let releaseCallback: GClosureNotify = { data, _ in
    if let data { Unmanaged<Callback>.fromOpaque(data).release() }
}

private let plainTrampoline: @convention(c) (W?, W?) -> Void = { instance, data in
    guard let data else { return }
    Unmanaged<Callback>.fromOpaque(data).takeUnretainedValue().run(instance, nil)
}

private let pairTrampoline: @convention(c) (W?, W?, W?) -> Void = { instance, argument, data in
    guard let data else { return }
    Unmanaged<Callback>.fromOpaque(data).takeUnretainedValue().run(instance, argument)
}

private let boolTrampoline: @convention(c) (W?, W?) -> gboolean = { instance, data in
    guard let data else { return 0 }
    Unmanaged<Callback>.fromOpaque(data).takeUnretainedValue().run(instance, nil)
    return 0
}

/// A signal whose handler takes only the instance: clicked, activate, toggled, activated, apply.
func on(_ instance: W?, _ signal: String, _ handler: @escaping () -> Void) {
    let box = Unmanaged.passRetained(Callback { _, _ in handler() }).toOpaque()
    _ = postern_connect(instance, signal, unsafeBitCast(plainTrampoline, to: GCallback.self), box, releaseCallback)
}

/// A signal whose handler takes one argument besides the instance: row-selected, row-activated, notify::….
func on(_ instance: W?, _ signal: String, argument handler: @escaping (W?) -> Void) {
    let box = Unmanaged.passRetained(Callback { _, argument in handler(argument) }).toOpaque()
    _ = postern_connect(instance, signal, unsafeBitCast(pairTrampoline, to: GCallback.self), box, releaseCallback)
}

/// close-request: the handler runs, the window closes.
func onClose(_ window: W?, _ handler: @escaping () -> Void) {
    let box = Unmanaged.passRetained(Callback { _, _ in handler() }).toOpaque()
    _ = postern_connect(window, "close-request", unsafeBitCast(boolTrampoline, to: GCallback.self), box, releaseCallback)
}

private let idleTrampoline: @convention(c) (gpointer?) -> gboolean = { data in
    guard let data else { return 0 }
    Unmanaged<Callback>.fromOpaque(data).takeRetainedValue().run(nil, nil)
    return 0
}

/// Runs on GTK's main thread, from any thread.
func onMain(_ work: @escaping () -> Void) {
    let box = Unmanaged.passRetained(Callback { _, _ in work() }).toOpaque()
    _ = g_idle_add(idleTrampoline, box)
}

private let timeoutTrampoline: @convention(c) (gpointer?) -> gboolean = { data in
    guard let data else { return 0 }
    Unmanaged<Callback>.fromOpaque(data).takeUnretainedValue().run(nil, nil)
    return 1
}

/// Runs every `seconds` on the main thread while the returned source lives.
@discardableResult
func every(_ seconds: UInt32, _ work: @escaping () -> Void) -> UInt32 {
    let box = Unmanaged.passRetained(Callback { _, _ in work() }).toOpaque()
    return g_timeout_add_seconds_full(G_PRIORITY_DEFAULT, seconds, timeoutTrampoline, box, { data in
        if let data { Unmanaged<Callback>.fromOpaque(data).release() }
    })
}

// MARK: Widgets

func label(_ text: String, _ classes: [String] = [], wrap: Bool = true, xalign: Float = 0, selectable: Bool = false) -> W? {
    let widget = raw(gtk_label_new(text))
    gtk_label_set_wrap(cast(widget), wrap ? 1 : 0)
    gtk_label_set_xalign(cast(widget), xalign)
    if selectable { gtk_label_set_selectable(cast(widget), 1) }
    for name in classes { gtk_widget_add_css_class(cast(widget), name) }
    return widget
}

func setText(_ labelWidget: W?, _ text: String) { gtk_label_set_text(cast(labelWidget), text) }

func box(_ vertical: Bool = true, spacing: Int32 = 6, _ children: [W?] = []) -> W? {
    let widget = raw(gtk_box_new(vertical ? GTK_ORIENTATION_VERTICAL : GTK_ORIENTATION_HORIZONTAL, spacing))
    for child in children { append(widget, child) }
    return widget
}

func append(_ container: W?, _ child: W?) {
    guard let child else { return }
    gtk_box_append(cast(container), cast(child))
}

func button(_ title: String, _ classes: [String] = [], _ action: @escaping () -> Void) -> W? {
    let widget = raw(gtk_button_new_with_label(title))
    for name in classes { gtk_widget_add_css_class(cast(widget), name) }
    gtk_widget_set_valign(cast(widget), GTK_ALIGN_CENTER)
    on(widget, "clicked", action)
    return widget
}

func iconButton(_ icon: String, tooltip: String, _ classes: [String] = ["flat"], _ action: @escaping () -> Void) -> W? {
    let widget = raw(gtk_button_new_from_icon_name(icon))
    gtk_widget_set_tooltip_text(cast(widget), tooltip)
    for name in classes { gtk_widget_add_css_class(cast(widget), name) }
    gtk_widget_set_valign(cast(widget), GTK_ALIGN_CENTER)
    on(widget, "clicked", action)
    return widget
}

func image(_ icon: String, size: Int32 = 16, _ classes: [String] = []) -> W? {
    let widget = raw(gtk_image_new_from_icon_name(icon))
    gtk_image_set_pixel_size(cast(widget), size)
    for name in classes { gtk_widget_add_css_class(cast(widget), name) }
    return widget
}

func addClass(_ widget: W?, _ name: String) { gtk_widget_add_css_class(cast(widget), name) }
func removeClass(_ widget: W?, _ name: String) { gtk_widget_remove_css_class(cast(widget), name) }
func setVisible(_ widget: W?, _ visible: Bool) { gtk_widget_set_visible(cast(widget), visible ? 1 : 0) }
func setSensitive(_ widget: W?, _ sensitive: Bool) { gtk_widget_set_sensitive(cast(widget), sensitive ? 1 : 0) }
func margins(_ widget: W?, _ value: Int32) {
    gtk_widget_set_margin_top(cast(widget), value)
    gtk_widget_set_margin_bottom(cast(widget), value)
    gtk_widget_set_margin_start(cast(widget), value)
    gtk_widget_set_margin_end(cast(widget), value)
}
func expand(_ widget: W?, horizontal: Bool = true, vertical: Bool = false) {
    gtk_widget_set_hexpand(cast(widget), horizontal ? 1 : 0)
    gtk_widget_set_vexpand(cast(widget), vertical ? 1 : 0)
}

// MARK: libadwaita rows and groups

func page() -> W? { raw(adw_preferences_page_new()) }

func group(_ title: String? = nil, description: String? = nil) -> W? {
    let widget = raw(adw_preferences_group_new())
    if let title { adw_preferences_group_set_title(opaque(widget), title) }
    if let description { adw_preferences_group_set_description(opaque(widget), description) }
    return widget
}

func addGroup(_ pageWidget: W?, _ groupWidget: W?) { adw_preferences_page_add(opaque(pageWidget), opaque(groupWidget)) }
func addRow(_ groupWidget: W?, _ row: W?) {
    guard let row else { return }
    adw_preferences_group_add(opaque(groupWidget), cast(row))
}
func groupSuffix(_ groupWidget: W?, _ suffix: W?) { adw_preferences_group_set_header_suffix(opaque(groupWidget), cast(suffix)) }

func actionRow(_ title: String, subtitle: String? = nil, icon: String? = nil, lines: Int32 = 0) -> W? {
    let widget = raw(adw_action_row_new())
    adw_preferences_row_set_title(cast(widget), title)
    adw_preferences_row_set_use_markup(cast(widget), 0)
    if let subtitle { adw_action_row_set_subtitle(cast(widget), subtitle) }
    if lines > 0 { adw_action_row_set_subtitle_lines(cast(widget), lines) }
    if let icon { adw_action_row_add_prefix(cast(widget), cast(image(icon, size: 16))) }
    return widget
}

func suffix(_ row: W?, _ widget: W?) {
    guard let widget else { return }
    adw_action_row_add_suffix(cast(row), cast(widget))
}

func prefix(_ row: W?, _ widget: W?) {
    guard let widget else { return }
    adw_action_row_add_prefix(cast(row), cast(widget))
}

func switchRow(_ title: String, subtitle: String?, active: Bool, _ changed: @escaping (Bool) -> Void) -> W? {
    let widget = raw(adw_switch_row_new())
    adw_preferences_row_set_title(cast(widget), title)
    adw_preferences_row_set_use_markup(cast(widget), 0)
    if let subtitle { adw_action_row_set_subtitle(cast(widget), subtitle) }
    adw_switch_row_set_active(opaque(widget), active ? 1 : 0)
    // notify:: handlers receive the GParamSpec before the user data.
    on(widget, "notify::active", argument: { _ in changed(adw_switch_row_get_active(opaque(widget)) != 0) })
    return widget
}

func setSwitch(_ row: W?, _ active: Bool) { adw_switch_row_set_active(opaque(row), active ? 1 : 0) }

func entryRow(_ title: String, text: String = "", password: Bool = false) -> W? {
    let widget = password ? raw(adw_password_entry_row_new()) : raw(adw_entry_row_new())
    adw_preferences_row_set_title(cast(widget), title)
    gtk_editable_set_text(opaque(widget), text)
    return widget
}

func text(of editable: W?) -> String { String(cString: gtk_editable_get_text(opaque(editable))) }

func spinRow(_ title: String, subtitle: String?, value: Double, range: ClosedRange<Double>, step: Double = 1) -> W? {
    let widget = raw(adw_spin_row_new_with_range(range.lowerBound, range.upperBound, step))
    adw_preferences_row_set_title(cast(widget), title)
    if let subtitle { adw_action_row_set_subtitle(cast(widget), subtitle) }
    adw_spin_row_set_value(opaque(widget), value)
    return widget
}

func spinValue(_ row: W?) -> Double { adw_spin_row_get_value(opaque(row)) }

func pill(_ text: String, _ style: String) -> W? {
    let widget = label(text, ["pill-badge", style], wrap: false, xalign: 0.5)
    gtk_widget_set_valign(cast(widget), GTK_ALIGN_CENTER)
    return widget
}

func textView(_ content: String, monospace: Bool = false) -> W? {
    let view = raw(gtk_text_view_new())
    gtk_text_view_set_editable(cast(view), 0)
    gtk_text_view_set_cursor_visible(cast(view), 0)
    gtk_text_view_set_wrap_mode(cast(view), GTK_WRAP_WORD_CHAR)
    gtk_text_view_set_monospace(cast(view), monospace ? 1 : 0)
    gtk_text_view_set_top_margin(cast(view), 12)
    gtk_text_view_set_bottom_margin(cast(view), 12)
    gtk_text_view_set_left_margin(cast(view), 14)
    gtk_text_view_set_right_margin(cast(view), 14)
    gtk_text_buffer_set_text(gtk_text_view_get_buffer(cast(view)), content, -1)
    return view
}

func scrolled(_ child: W?, minHeight: Int32 = 0, maxHeight: Int32 = -1) -> W? {
    let widget = raw(gtk_scrolled_window_new())
    gtk_scrolled_window_set_child(cast(widget), cast(child))
    gtk_scrolled_window_set_policy(cast(widget), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
    if minHeight > 0 { gtk_scrolled_window_set_min_content_height(cast(widget), minHeight) }
    if maxHeight > 0 {
        gtk_scrolled_window_set_max_content_height(cast(widget), maxHeight)
        gtk_scrolled_window_set_propagate_natural_height(cast(widget), 1)
    }
    return widget
}

func copyToClipboard(_ widget: W?, _ text: String) {
    gdk_clipboard_set_text(gtk_widget_get_clipboard(cast(widget)), text)
}

func toast(_ overlay: W?, _ text: String) {
    adw_toast_overlay_add_toast(opaque(overlay), adw_toast_new(text))
}

/// Proton's colors on libadwaita's widgets: its purple accent, its warm greys, its pills.
func installStyle() {
    let css = """
    @define-color accent_bg_color #6D4AFF;
    @define-color accent_color #6D4AFF;
    @define-color accent_fg_color #FFFFFF;
    @define-color destructive_bg_color #DC3251;
    @define-color success_color #1EA885;
    @define-color warning_color #FF8D3F;
    .navigation-sidebar { background: #1B1340; color: #FFFFFF; }
    .navigation-sidebar row { border-radius: 8px; margin: 2px 8px; padding: 8px 10px; }
    .navigation-sidebar row:selected { background: alpha(#FFFFFF, 0.14); }
    .navigation-sidebar label.dim-label { color: alpha(#FFFFFF, 0.6); }
    .sidebar-pane { background: #1B1340; }
    .sidebar-pane headerbar { background: #1B1340; color: #FFFFFF; box-shadow: none; }
    .count-badge { background: #6D4AFF; color: #FFFFFF; border-radius: 6px; padding: 1px 7px; font-weight: 600; font-size: 0.85em; }
    .pill-badge { border-radius: 999px; padding: 2px 10px; font-weight: 700; font-size: 0.78em; }
    .pill-badge.warning { background: #FF8D3F; color: #FFFFFF; }
    .pill-badge.danger { background: #DC3251; color: #FFFFFF; }
    .pill-badge.success { background: #1EA885; color: #FFFFFF; }
    .pill-badge.neutral { background: alpha(currentColor, 0.12); }
    .hero { padding: 18px; border-radius: 12px; background: alpha(#6D4AFF, 0.08); }
    .hero-mark { background: #FFFFFF; border-radius: 14px; padding: 10px; }
    .email-card { border-radius: 12px; border: 1px solid alpha(currentColor, 0.15); background: @view_bg_color; }
    .email-head { padding: 14px 16px; background: alpha(currentColor, 0.04); border-radius: 12px 12px 0 0; }
    .tier-icon { border-radius: 8px; padding: 6px; background: alpha(#6D4AFF, 0.12); color: #6D4AFF; }
    .tier-icon.send { background: alpha(#FF8D3F, 0.15); color: #E27424; }
    .tier-icon.delete { background: alpha(#DC3251, 0.12); color: #DC3251; }
    .warning-box { border-radius: 10px; padding: 10px 14px; background: alpha(#DC3251, 0.12); }
    .notice-box { border-radius: 10px; padding: 10px 14px; background: alpha(#FF8D3F, 0.14); }
    .gauge levelbar block.filled { background: #6D4AFF; }
    """
    let provider = gtk_css_provider_new()
    gtk_css_provider_load_from_string(provider, css)
    gtk_style_context_add_provider_for_display(gdk_display_get_default(), cast(raw(provider)), UInt32(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION))
}
#endif
