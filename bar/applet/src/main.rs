// Maprisma Settings (formerly Maprisma Manager) for COSMIC: its icon in the panel. A click opens
// Maprisma Settings when it is
// closed or hidden and hides it when it is shown, in front or not (it may be installing
// something, so it is hidden, not closed).
//
// That is the app's own: `maprisma-settings --toggle` (single instance). The applet's id, icon name
// and D-Bus names keep "CosmicMaprismaManager": COSMIC's panel configuration lists the applet by
// that id, so a new id would drop the icon from the user's panel.

mod fonts;

use std::path::PathBuf;
use std::process::Stdio;
use std::sync::LazyLock;

use cosmic::app::{Core, Task};
use cosmic::applet::cosmic_panel_config::PanelAnchor;
use cosmic::widget::{Id, autosize, button, icon};
use cosmic::{Element, theme};

const APP_ID: &str = "io.github.ubruckhaus.CosmicMaprismaManager";
const ICON: &str = "io.github.ubruckhaus.CosmicMaprismaManager-symbolic";
static AUTOSIZE_ID: LazyLock<Id> = LazyLock::new(|| Id::new("manager-autosize"));

fn main() -> cosmic::iced::Result {
    fonts::keep_fonts();
    cosmic::applet::run::<Applet>(())
}

// MAPRISMA_MANAGER, or the link tools/install-local makes (the old name of an earlier install
// too), or one on PATH.
fn manager_bin() -> PathBuf {
    if let Some(path) = std::env::var_os("MAPRISMA_MANAGER") {
        return PathBuf::from(path);
    }
    let bin = PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".local/bin");
    for name in ["maprisma-settings", "maprisma-manager"] {
        if bin.join(name).exists() {
            return bin.join(name);
        }
    }
    PathBuf::from("maprisma-settings")
}

fn toggle() {
    let child = std::process::Command::new(manager_bin())
        .arg("--toggle")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
    if let Ok(mut child) = child {
        std::thread::spawn(move || {
            let _ = child.wait();
        });
    }
}

#[derive(Default)]
struct Applet {
    core: Core,
}

#[derive(Debug, Clone)]
enum Message {
    Toggle,
}

impl cosmic::Application for Applet {
    type Executor = cosmic::SingleThreadExecutor;
    type Flags = ();
    type Message = Message;
    const APP_ID: &'static str = APP_ID;

    fn core(&self) -> &Core {
        &self.core
    }

    fn core_mut(&mut self) -> &mut Core {
        &mut self.core
    }

    fn init(core: Core, _flags: ()) -> (Self, Task<Message>) {
        (Self { core }, Task::none())
    }

    fn update(&mut self, message: Message) -> Task<Message> {
        match message {
            Message::Toggle => toggle(),
        }
        Task::none()
    }

    fn view(&self) -> Element<'_, Message> {
        fonts::keep_fonts();
        let horizontal = matches!(self.core.applet.anchor, PanelAnchor::Top | PanelAnchor::Bottom);
        let padding = self.core.applet.suggested_padding(true).0;
        let size = self.core.applet.suggested_size(true).0;
        let button = button::custom(icon::from_name(ICON).size(size).symbolic(true).icon())
            .padding(if horizontal { [0, padding] } else { [padding, 0] })
            .on_press_down(Message::Toggle)
            .class(theme::Button::AppletIcon);
        autosize::autosize(button, AUTOSIZE_ID.clone()).into()
    }

    fn style(&self) -> Option<cosmic::iced::theme::Style> {
        Some(cosmic::applet::style())
    }
}
