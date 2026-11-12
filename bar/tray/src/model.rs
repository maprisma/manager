/// What a click in the tray or its menu does.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    /// The icon: open, bring to the front, or hide when in front (`--toggle`).
    Toggle,
    /// A menu entry: open on this page (`--page <page>`); None: the page it had.
    Open(Option<&'static str>),
    Quit,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Item {
    pub id: i32,
    pub label: String,
    pub separator: bool,
    pub children: Vec<Item>,
    action: Option<Action>,
}

impl Item {
    pub fn find(&self, id: i32) -> Option<&Self> {
        if self.id == id {
            Some(self)
        } else {
            self.children.iter().find_map(|c| c.find(id))
        }
    }
    pub fn activate(&self, id: i32) -> Option<Action> {
        self.find(id).and_then(|i| i.action)
    }
}

/// The pages the menu offers, as the sidebar names them (flutter_app/lib/home.dart Section).
pub const PAGES: [(&str, &str); 8] = [
    ("apps", "Apps"),
    ("network", "Network & Wireless"),
    ("bluetooth", "Bluetooth"),
    ("sound", "Sound"),
    ("displays", "Displays"),
    ("power", "Power"),
    ("bar", "Bar"),
    ("settings", "Settings"),
];

pub fn menu() -> Item {
    let item = |id, label: &str, action| Item {
        id,
        label: label.into(),
        separator: false,
        children: vec![],
        action,
    };
    let separator = |id| Item {
        separator: true,
        ..item(id, "", None)
    };
    let mut root = item(0, "", None);
    root.children.push(item(1, "Open Maprisma Manager", Some(Action::Open(None))));
    root.children.push(separator(2));
    for (i, (key, label)) in PAGES.iter().enumerate() {
        root.children.push(item(10 + i as i32, label, Some(Action::Open(Some(key)))));
    }
    root.children.push(separator(3));
    root.children.push(item(4, "Quit tray", Some(Action::Quit)));
    root
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn menu_actions() {
        let m = menu();
        assert_eq!(m.children.len(), 12);
        assert_eq!(m.activate(1), Some(Action::Open(None)));
        assert_eq!(m.activate(12), Some(Action::Open(Some("bluetooth"))));
        assert_eq!(m.find(12).unwrap().label, "Bluetooth");
        assert_eq!(m.activate(4), Some(Action::Quit));
        assert_eq!(m.activate(2), None);
        assert_eq!(m.activate(0), None);
        assert_eq!(m.activate(99), None);
    }
}
