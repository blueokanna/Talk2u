//! Wire rules that belong to the model, not to this app.
//!
//! Zhipu's `thinking` parameter is not uniform: `glm-4.7` and `glm-4.7-flash`
//! *always* think and answer `400` for `thinking.type: "disabled"`, while
//! `glm-4-long` has no thinking at all. Those facts live in `rustglm`'s
//! capability registry, which is generated from the vendor contract; duplicating
//! them here is how the app previously ended up sending a disabled flag to two
//! models that reject it.
//!
//! The registry is deliberately incomplete: it returns `None` for private
//! deployments and models released after the crate. `None` means "say nothing
//! and let the provider apply its own default", never "assume it supports this".

use rustglm::Thinking;

/// What the request body should carry for `thinking`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ThinkingWire {
    /// Omit the field entirely.
    Omit,
    /// `{"type": "enabled"}`.
    Enabled,
    /// `{"type": "disabled"}`.
    Disabled,
}

impl ThinkingWire {
    /// The exact object to place in the request body, or `None` to leave the
    /// field out.
    ///
    /// The value is serialised from [`rustglm::Thinking`], so a key the vendor
    /// does not accept cannot appear here; `serde_json` is only the container
    /// the rest of the request builder works in.
    pub(crate) fn body(self) -> Option<serde_json::Value> {
        let thinking = match self {
            Self::Omit => return None,
            Self::Enabled => Thinking::enabled(),
            Self::Disabled => Thinking::disabled(),
        };
        let encoded = nextjson::to_string(&thinking).ok()?;
        serde_json::from_str(&encoded).ok()
    }
}

/// Models that predate the SDK registry but still ship as app defaults.
///
/// `glm-4-air` is the built-in "deep reasoning" model; it accepts both
/// `enabled` and `disabled`, so it keeps honouring the user's toggle.
const LEGACY_TOGGLEABLE: &[&str] = &["glm-4-air", "glm-4-airx", "glm-4-plus"];

/// Decides what to send for `thinking`, given the model and the user's choice.
pub(crate) fn thinking_for(model: &str, user_wants_thinking: bool) -> ThinkingWire {
    if let Some(capabilities) = rustglm::ModelCapabilities::of(model) {
        if !capabilities.thinking {
            return ThinkingWire::Omit;
        }
        if user_wants_thinking {
            return ThinkingWire::Enabled;
        }
        return if capabilities.allows_disabled_thinking() {
            ThinkingWire::Disabled
        } else {
            // The model always reasons; asking it not to is a wire error, so
            // the only correct request omits the field.
            ThinkingWire::Omit
        };
    }

    if LEGACY_TOGGLEABLE.contains(&model) {
        return if user_wants_thinking {
            ThinkingWire::Enabled
        } else {
            ThinkingWire::Disabled
        };
    }

    ThinkingWire::Omit
}

/// Whether the model reasons at all, which is what the model picker advertises.
///
/// Distinct from "the toggle is honoured": `glm-4.7` always reasons, so it gets
/// the badge even though asking it not to is a wire error.
pub(crate) fn can_reason(model: &str) -> bool {
    match rustglm::ModelCapabilities::of(model) {
        Some(capabilities) => capabilities.thinking,
        None => LEGACY_TOGGLEABLE.contains(&model),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn always_thinking_models_never_get_a_disabled_flag() {
        for model in ["glm-4.7", "glm-4.7-flash", "glm-4.7-flashx"] {
            assert_eq!(thinking_for(model, false), ThinkingWire::Omit, "{model}");
            assert_eq!(thinking_for(model, true), ThinkingWire::Enabled, "{model}");
            assert!(can_reason(model), "{model} reasons unconditionally");
        }
    }

    #[test]
    fn models_without_thinking_get_no_field() {
        for model in ["glm-4-long", "charglm-4", "emohaa"] {
            assert_eq!(thinking_for(model, true), ThinkingWire::Omit, "{model}");
            assert!(!can_reason(model), "{model} has no thinking");
        }
    }

    #[test]
    fn toggleable_models_honour_the_switch() {
        for model in ["glm-5.2", "glm-4.6", "glm-4.5-air"] {
            assert_eq!(thinking_for(model, true), ThinkingWire::Enabled, "{model}");
            assert_eq!(thinking_for(model, false), ThinkingWire::Disabled, "{model}");
            assert!(can_reason(model), "{model}");
        }
    }

    #[test]
    fn legacy_and_unknown_models_stay_conservative() {
        assert_eq!(thinking_for("glm-4-air", true), ThinkingWire::Enabled);
        assert_eq!(thinking_for("glm-4-air", false), ThinkingWire::Disabled);
        assert!(can_reason("glm-4-air"));

        // A private deployment: no assumption, no field.
        assert_eq!(thinking_for("my-local-glm", true), ThinkingWire::Omit);
        assert!(!can_reason("my-local-glm"));
    }

    #[test]
    fn wire_objects_carry_only_documented_keys() {
        assert!(ThinkingWire::Omit.body().is_none());

        let enabled = ThinkingWire::Enabled.body().expect("enabled body");
        assert_eq!(enabled.get("type").and_then(|v| v.as_str()), Some("enabled"));
        assert!(enabled.get("budget_tokens").is_none());

        let disabled = ThinkingWire::Disabled.body().expect("disabled body");
        assert_eq!(
            disabled.get("type").and_then(|v| v.as_str()),
            Some("disabled")
        );
    }
}
