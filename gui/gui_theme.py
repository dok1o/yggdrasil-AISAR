# gui_theme.py — Unified Theme Loader (Custom + Fallback)

import sys

# --- Fallback Defaults (Light/Basic) ---
_W = "#ffffff"
_B = "#000000"
_G = "#cccccc"
_M = "#6b7280"

DEFAULT_STYLE = f"color: {_B}; font-size: 11px; background: transparent;"
DEFAULT_STYLE_G = f"color: {_G}; font-size: 11px; background: transparent;"


def _fallback_stylesheet() -> str:
    """Fallback global stylesheet applied when custom theme is unavailable."""
    return (
        f"QWidget {{ background-color: {_W}; color: {_B}; font-family: sans-serif; }} "
        f"QLabel {{ background: transparent; }} "
        f"QMenu::item:disabled {{ color: {_M}; opacity: 0.55; }} "
        f"QFrame {{ border: 1px solid #e2e8f0; border-radius: 8px; }} "
        f"QPushButton {{ background-color: #f3f4f6; border: 1px solid #d1d5db; border-radius: 6px; padding: 6px 12px; }}"
    )


def _apply_fallback(component: str, kind=None, **kwargs) -> str:
    muted = kwargs.get("muted", False)
    active = kwargs.get("active", False)
    positive = kwargs.get("positive", False)

    if component == "summary":
        return f"background-color: {_W}; color: {_B}; border: 1px solid {_G}; border-radius: 6px; padding: 8px 12px; font-size: 13px;"
    
    elif component == "label":
        return DEFAULT_STYLE_G
    
    elif component == "section_label":
        return DEFAULT_STYLE
    
    elif component == "log":
        return f"font-family: monospace; font-size: 11px; background-color: {_W}; color: {_B}; border: 1px solid {_G}; padding: 4px;"
    
    elif component in ("metric_card", "metric_name", "metric_total", "metric_delta"):
        if component == "metric_card":
            return DEFAULT_STYLE
        elif component == "metric_name":
            return DEFAULT_STYLE_G
        elif component == "metric_total":
            return DEFAULT_STYLE if active else DEFAULT_STYLE_G
        elif component == "metric_delta":
            return DEFAULT_STYLE if positive else DEFAULT_STYLE_G
    
    elif component.startswith("hero_"):
        if component == "hero_card":
            return f"background-color: {_W}; border: 1px solid {_G}; border-radius: 12px;"
        return DEFAULT_STYLE
    
    # Default fallback for unknown components
    return DEFAULT_STYLE


# --- Dynamic Theme Loading ---
USE_CUSTOM_THEME = False
_ext_apply_theme = None
_ext_set_app_theme = None

try:
    from themes.deep_space_glass_theme_mod import (
        set_app_theme as _ext_set_app_theme,
        apply_theme as _ext_apply_theme,
    )
    USE_CUSTOM_THEME = True
except ImportError:
    pass


def set_app_theme(app) -> None:
    """Applies the global application stylesheet via the active theme backend."""
    if USE_CUSTOM_THEME and _ext_set_app_theme is not None:
        try:
            _ext_set_app_theme(app)
        except Exception as e:
            print(f"[gui_theme] Custom theme failed: {e}. Falling back to defaults.")
            app.setStyleSheet(_fallback_stylesheet())
    else:
        app.setStyleSheet(_fallback_stylesheet())


def apply_theme(component: str, kind=None, **kwargs) -> str:
    if USE_CUSTOM_THEME and _ext_apply_theme is not None:
        try:
            extra_kwargs = kwargs.copy()
            if kind is not None:
                extra_kwargs["kind"] = kind
            return _ext_apply_theme(component, **extra_kwargs)
        except Exception as e:
            print(f"[gui_theme] Custom apply_theme failed for '{component}': {e}. Using fallback.")
            #return _apply_fallback(component, kind=kind, **kwargs)
    
    else:        
        return _apply_fallback(component, kind=kind, **kwargs)