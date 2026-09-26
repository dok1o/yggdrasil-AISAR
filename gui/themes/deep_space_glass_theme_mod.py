# deep_space_glass_theme_mod.py — magnet_sorter dark theme (2026 "deep space glass")
#
# Design language:
#   - Deep charcoal-blue surfaces with layered elevation
#   - Electric violet primary accent + cyan informational accent
#   - 10-12px radii, hairline borders, translucent accent tints
#   - Tabular numerals for metrics, generous letter spacing on captions

BG_WINDOW = "#0b0e14"
BG_PANEL = "#121826"
BG_HEADER = "#1a2233"
BG_ALT = "#0e131d"
BG_INPUT = "#0e141f"
BG_LOG = "#0d1117"
BG_CARD = "#111827"

BORDER = "#222c40"
BORDER_SOFT = "#1a2233"
BORDER_FOCUS = "#7c5cff"

TEXT_PRIMARY = "#e9edf5"
TEXT_SECONDARY = "#a8b3c7"
TEXT_MUTED = "#5d6b82"
TEXT_ON_ACCENT = "#ffffff"
TEXT_DISABLED = "#4a5568"  # ← Dedicated disabled tone for menus/controls

ACCENT = "#7c5cff"          # electric violet
ACCENT_SUCCESS = "#34d399"  # mint
ACCENT_WARNING = "#fbbf24"  # amber
ACCENT_ERROR = "#fb7185"    # coral
ACCENT_INFO = "#38bdf8"     # sky cyan

COLOR_RUNTIME = ACCENT_WARNING
COLOR_UTM = ACCENT_INFO
COLOR_FLICKER = ACCENT_SUCCESS
COLOR_ACTIVE = TEXT_PRIMARY
COLOR_MUTED = TEXT_MUTED

# Translucent accent tints for chips / cards
TINT_VIOLET = "rgba(124, 92, 255, 0.14)"
TINT_CYAN = "rgba(56, 189, 248, 0.12)"
TINT_GREEN = "rgba(52, 211, 153, 0.12)"
TINT_AMBER = "rgba(251, 191, 36, 0.12)"
TINT_RED = "rgba(251, 113, 133, 0.13)"

HERO_KINDS = {
    "runtime": (ACCENT_WARNING, TINT_AMBER, "rgba(251, 191, 36, 0.28)"),
    "utm":     (ACCENT_INFO, TINT_CYAN, "rgba(56, 189, 248, 0.28)"),
    "via_utp": (ACCENT, TINT_VIOLET, "rgba(124, 92, 255, 0.28)"),
    "via_tcp": (ACCENT_SUCCESS, TINT_GREEN, "rgba(52, 211, 153, 0.28)"),
}

SUMMARY_KINDS = {
    "runtime": (COLOR_RUNTIME, TINT_AMBER, "rgba(251, 191, 36, 0.3)"),
    "utm": (COLOR_UTM, TINT_CYAN, "rgba(56, 189, 248, 0.3)"),
    "connected": (ACCENT_SUCCESS, TINT_GREEN, "rgba(52, 211, 153, 0.3)"),
    "disconnected": (ACCENT_ERROR, TINT_RED, "rgba(251, 113, 133, 0.3)"),
    "default": (TEXT_SECONDARY, BG_PANEL, BORDER)
}

FONT_UI = '"Segoe UI Variable Display", "Segoe UI", "Inter", "Helvetica Neue", sans-serif'
FONT_MONO = '"Cascadia Mono", "JetBrains Mono", "Consolas", monospace'

def app_stylesheet() -> str:
    return f"""
    QWidget {{
        background-color: {BG_WINDOW};
        color: {TEXT_PRIMARY};
        font-family: {FONT_UI};
        font-size: 12px;
    }}
    QToolTip {{
        background-color: {BG_HEADER};
        color: {TEXT_PRIMARY};
        border: 1px solid {BORDER};
        border-radius: 6px;
        padding: 6px 8px;
    }}
    QMenuBar {{
        background-color: {BG_WINDOW};
        border-bottom: 1px solid {BORDER_SOFT};
        padding: 3px 6px;
    }}
    QMenuBar::item {{
        padding: 5px 12px;
        background: transparent;
        border-radius: 6px;
        color: {TEXT_SECONDARY};
    }}
    QMenuBar::item:selected {{
        background-color: {BG_HEADER};
        color: {TEXT_PRIMARY};
    }}
    QMenu {{
        background-color: {BG_PANEL};
        border: 1px solid {BORDER};
        border-radius: 10px;
        padding: 6px;
    }}
    QMenu::item {{
        padding: 7px 28px 7px 14px;
        border-radius: 6px;
        color: {TEXT_PRIMARY};
    }}
    QMenu::item:disabled {{
        color: {TEXT_DISABLED};
        opacity: 0.55;
        }}
    QMenu::item:selected {{
        background-color: {TINT_VIOLET};
        color: {TEXT_PRIMARY};
    }}
    QMenu::separator {{
        height: 1px;
        background: {BORDER_SOFT};
        margin: 5px 10px;
    }}
    QTabWidget::pane {{
        border: 1px solid {BORDER_SOFT};
        border-radius: 12px;
        background: {BG_WINDOW};
        top: 6px;
    }}
    QTabBar {{
        qproperty-drawBase: 0;
    }}
    QTabBar::tab {{
        background: transparent;
        color: {TEXT_MUTED};
        border: 1px solid transparent;
        padding: 7px 18px;
        margin-right: 6px;
        border-radius: 8px;
        font-weight: 600;
    }}
    QTabBar::tab:selected {{
        background: {TINT_VIOLET};
        color: {TEXT_PRIMARY};
        border: 1px solid rgba(124, 92, 255, 0.35);
    }}
    QTabBar::tab:hover:!selected {{
        background: {BG_HEADER};
        color: {TEXT_SECONDARY};
    }}
    QPushButton {{
        background-color: {BG_PANEL};
        color: {TEXT_PRIMARY};
        border: 1px solid {BORDER};
        border-radius: 8px;
        padding: 6px 14px;
        min-height: 20px;
        font-weight: 600;
    }}
    QPushButton:hover {{
        background-color: {BG_HEADER};
        border-color: rgba(124, 92, 255, 0.55);
    }}
    QPushButton:pressed {{
        background-color: {TINT_VIOLET};
    }}
    QPushButton:disabled {{
        color: {TEXT_MUTED};
        background-color: {BG_ALT};
        border-color: {BORDER_SOFT};
    }}
    QPushButton:checked {{
        background-color: {TINT_VIOLET};
        border-color: {ACCENT};
        color: {TEXT_PRIMARY};
    }}
    QLineEdit, QSpinBox, QTextEdit, QPlainTextEdit, QComboBox {{
        background-color: {BG_INPUT};
        color: {TEXT_PRIMARY};
        border: 1px solid {BORDER};
        border-radius: 8px;
        padding: 6px 10px;
        selection-background-color: rgba(124, 92, 255, 0.45);
        selection-color: {TEXT_ON_ACCENT};
    }}
    QLineEdit:focus, QSpinBox:focus, QTextEdit:focus, QComboBox:focus {{
        border: 1px solid {BORDER_FOCUS};
        background-color: {BG_ALT};
    }}
    QListWidget, QTreeWidget, QTableWidget {{
        background-color: {BG_ALT};
        alternate-background-color: {BG_PANEL};
        color: {TEXT_PRIMARY};
        border: 1px solid {BORDER_SOFT};
        border-radius: 10px;
        outline: none;
    }}
    QListWidget::item, QTreeWidget::item, QTableWidget::item {{
        padding: 4px 6px;
        border-radius: 4px;
    }}
    QListWidget::item:hover, QTreeWidget::item:hover {{
        background-color: {BG_HEADER};
    }}
    QListWidget::item:selected,
    QTreeWidget::item:selected,
    QTableWidget::item:selected {{
        background-color: {TINT_VIOLET};
        color: {TEXT_PRIMARY};
    }}
    QHeaderView::section {{
        background-color: {BG_WINDOW};
        color: {TEXT_MUTED};
        border: none;
        border-bottom: 1px solid {BORDER};
        padding: 7px 8px;
        font-weight: 700;
        text-transform: uppercase;
        font-size: 10px;
        letter-spacing: 0.6px;
    }}
    QSplitter::handle {{
        background-color: {BORDER_SOFT};
    }}
    QScrollBar:vertical {{
        background: transparent;
        width: 10px;
        margin: 2px;
    }}
    QScrollBar::handle:vertical {{
        background: {BORDER};
        border-radius: 4px;
        min-height: 24px;
    }}
    QScrollBar::handle:vertical:hover {{
        background: {TEXT_MUTED};
    }}
    QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical {{
        height: 0;
    }}
    QScrollBar:horizontal {{
        background: transparent;
        height: 10px;
        margin: 2px;
    }}
    QScrollBar::handle:horizontal {{
        background: {BORDER};
        border-radius: 4px;
        min-width: 24px;
    }}
    QScrollBar::add-line:horizontal, QScrollBar::sub-line:horizontal {{
        width: 0;
    }}
    QCheckBox {{
        spacing: 7px;
        color: {TEXT_SECONDARY};
    }}
    QCheckBox::indicator {{
        width: 15px;
        height: 15px;
        border: 1px solid {BORDER};
        border-radius: 4px;
        background: {BG_INPUT};
    }}
    QCheckBox::indicator:checked {{
        background: {ACCENT};
        border-color: {ACCENT};
    }}
    QFrame[frameShape="4"] {{
        color: {BORDER_SOFT};
    }}
    QFrame#metricCard {{
        background-color: {BG_CARD};
        border: 1px solid {BORDER_SOFT};
        border-style: solid;
        border-radius: 12px;
    }}
    QFrame#heroCard {{
        border-radius: 12px;
    }}
    QLabel {{
        background: transparent;
    }}
    """

def set_app_theme(app) -> None:
    """Applies the global application stylesheet."""
    app.setStyleSheet(app_stylesheet())

def apply_theme(component: str, **kwargs) -> str:
    kind = kwargs.get("kind")
    #muted = kwargs.get("muted", False)
    active = kwargs.get("active", False)
    positive = kwargs.get("positive", False)

    if component == "summary":
        fg, bg, border = SUMMARY_KINDS.get(kind, (TEXT_SECONDARY, BG_PANEL, BORDER))
        return (
            f"background-color: {bg}; color: {fg}; "
            f"border: 1px solid {border}; border-radius: 10px; "
            f"padding: 10px 16px; font-size: 13px; font-weight: 600; "
            f"letter-spacing: 0.2px;"
        )

    elif component == "label":
        return (
            f"color: {TEXT_MUTED}; font-size: 10px; padding-top: 0px; "
            f"background: transparent;"
        )

    elif component == "log":
        return (
            f"font-family: {FONT_MONO}; font-size: 11px; "
            f"background: {BG_LOG}; color: {TEXT_SECONDARY}; "
            f"border: 1px solid {BORDER_SOFT}; border-radius: 10px; "
            f"padding: 4px;"
        )

    elif component == "metric_card":
        # Changed to regular/medium weight, removed uppercase forcing
        return (
            f"color: {TEXT_SECONDARY}; font-size: 12px; font-weight: 500; "
            f"letter-spacing: 0.1px; padding: 6px 0 8px 0; background: transparent;"
        )

    elif component == "metric_label":
        return (
            # f"color: {TEXT_MUTED}; font-size: 10px; font-weight: 700; "
            # f"text-transform: uppercase; letter-spacing: 1.2px; "
            # f"padding: 4px 0 2px 0; background: transparent;"
            f"color: {TEXT_SECONDARY}; font-size: 11px; background: transparent;"
        )

    # elif component == "metric_name":
    #     return (
    #         f"color: {color}; font-size: 10px; font-weight: 700; "
    #         f"text-transform: uppercase; letter-spacing: 1.1px; "
    #         f"padding: 0; background: transparent;"
            #f"color: {TEXT_SECONDARY}; font-size: 30px; background: transparent;"

    elif component == "metric_total":
        color = TEXT_PRIMARY if active else TEXT_MUTED
        return f"color: {color}; font-size: 12px; font-weight: 700; background: transparent;"

    elif component == "metric_delta":
        if positive:
            return (
                f"color: {ACCENT_SUCCESS}; font-size: 10px; font-weight: 700; "
                f"background: {TINT_GREEN}; border-radius: 6px; padding: 1px 6px;"
            )
        return f"color: {TEXT_MUTED}; font-size: 10px; background: transparent; padding: 1px 6px;"

    elif component in ("hero_card", "hero_cap", "hero_value"):
        fg, tint, border = HERO_KINDS.get(kind, (TEXT_PRIMARY, TINT_VIOLET, BORDER))
        if component == "hero_card":
            return f"background-color: {tint}; border: 0px solid {border}; border-radius: 12px;"
        elif component == "hero_cap":
            # Changed to regular/medium weight
            return (
                f"color: {fg}; font-size: 10px; font-weight: 500; "
                f"letter-spacing: 0.5px; background: transparent;"
            )
        elif component == "hero_value":
            return f"color: {fg}; font-size: 19px; font-weight: 700; background: transparent;"

    raise ValueError(f"Unknown theme component: '{component}'")