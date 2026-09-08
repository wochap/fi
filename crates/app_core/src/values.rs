use std::{cmp::Ordering, fmt, str::FromStr};

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::schema::EnumOptionId;

pub const MAX_DECIMAL_SCALE: u8 = 18;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct FixedDecimal {
    representation: i64,
    scale: u8,
}

#[derive(Clone, Debug, Error, Eq, PartialEq)]
pub enum DecimalError {
    #[error("decimal scale {0} exceeds the supported maximum of {MAX_DECIMAL_SCALE}")]
    InvalidScale(u8),
    #[error("invalid decimal syntax")]
    InvalidSyntax,
    #[error("decimal has more than {scale} fractional digits")]
    ExcessPrecision { scale: u8 },
    #[error("decimal representation overflows a signed 64-bit integer")]
    Overflow,
    #[error("decimal scales are incompatible: {left} and {right}")]
    IncompatibleScale { left: u8, right: u8 },
}

impl FixedDecimal {
    pub fn new(representation: i64, scale: u8) -> Result<Self, DecimalError> {
        if scale > MAX_DECIMAL_SCALE {
            return Err(DecimalError::InvalidScale(scale));
        }
        Ok(Self {
            representation,
            scale,
        })
    }

    pub fn parse(value: &str, scale: u8) -> Result<Self, DecimalError> {
        if scale > MAX_DECIMAL_SCALE {
            return Err(DecimalError::InvalidScale(scale));
        }
        if value.is_empty() || value.trim() != value {
            return Err(DecimalError::InvalidSyntax);
        }
        let (negative, unsigned) = match value.as_bytes().first() {
            Some(b'-') => (true, &value[1..]),
            Some(b'+') => (false, &value[1..]),
            _ => (false, value),
        };
        if unsigned.is_empty() {
            return Err(DecimalError::InvalidSyntax);
        }
        let mut parts = unsigned.split('.');
        let whole = parts.next().unwrap_or_default();
        let fraction = parts.next();
        if parts.next().is_some()
            || whole.is_empty()
            || !whole.bytes().all(|byte| byte.is_ascii_digit())
            || fraction.is_some_and(|part| !part.bytes().all(|byte| byte.is_ascii_digit()))
        {
            return Err(DecimalError::InvalidSyntax);
        }
        let fraction = fraction.unwrap_or_default();
        if fraction.len() > usize::from(scale) {
            return Err(DecimalError::ExcessPrecision { scale });
        }
        let factor = 10_i128.pow(u32::from(scale));
        let whole = i128::from_str(whole).map_err(|_| DecimalError::Overflow)?;
        let fractional = if fraction.is_empty() {
            0
        } else {
            i128::from_str(fraction).map_err(|_| DecimalError::Overflow)?
                * 10_i128.pow(u32::from(scale) - fraction.len() as u32)
        };
        let magnitude = whole
            .checked_mul(factor)
            .and_then(|value| value.checked_add(fractional))
            .ok_or(DecimalError::Overflow)?;
        let signed = if negative { -magnitude } else { magnitude };
        let representation = i64::try_from(signed).map_err(|_| DecimalError::Overflow)?;
        Self::new(representation, scale)
    }

    #[must_use]
    pub const fn representation(self) -> i64 {
        self.representation
    }

    #[must_use]
    pub const fn scale(self) -> u8 {
        self.scale
    }

    pub fn checked_add(self, other: Self) -> Result<Self, DecimalError> {
        self.ensure_scale(other)?;
        Self::new(
            self.representation
                .checked_add(other.representation)
                .ok_or(DecimalError::Overflow)?,
            self.scale,
        )
    }

    pub fn checked_sub(self, other: Self) -> Result<Self, DecimalError> {
        self.ensure_scale(other)?;
        Self::new(
            self.representation
                .checked_sub(other.representation)
                .ok_or(DecimalError::Overflow)?,
            self.scale,
        )
    }

    pub fn checked_sum<I>(values: I) -> Result<Self, DecimalError>
    where
        I: IntoIterator<Item = Self>,
    {
        let mut values = values.into_iter();
        let mut sum = values.next().ok_or(DecimalError::InvalidSyntax)?;
        for value in values {
            sum = sum.checked_add(value)?;
        }
        Ok(sum)
    }

    pub fn checked_cmp(self, other: Self) -> Result<Ordering, DecimalError> {
        self.ensure_scale(other)?;
        Ok(self.representation.cmp(&other.representation))
    }

    fn ensure_scale(self, other: Self) -> Result<(), DecimalError> {
        if self.scale == other.scale {
            Ok(())
        } else {
            Err(DecimalError::IncompatibleScale {
                left: self.scale,
                right: other.scale,
            })
        }
    }
}

impl fmt::Display for FixedDecimal {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let magnitude = i128::from(self.representation).abs();
        if self.scale == 0 {
            return write!(
                formatter,
                "{}{}",
                if self.representation < 0 { "-" } else { "" },
                magnitude
            );
        }
        let factor = 10_i128.pow(u32::from(self.scale));
        write!(
            formatter,
            "{}{}.{:0width$}",
            if self.representation < 0 { "-" } else { "" },
            magnitude / factor,
            magnitude % factor,
            width = usize::from(self.scale)
        )
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "value", rename_all = "snake_case")]
pub enum FieldValue {
    Null,
    Text(String),
    Integer(i64),
    FixedDecimal(i64),
    Boolean(bool),
    Date(i64),
    DateTime(i64),
    Duration(i64),
    Enum(EnumOptionId),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decimal_parse_format_and_boundaries_are_exact() {
        assert_eq!(
            FixedDecimal::parse("-900.00", 2).unwrap().representation(),
            -90_000
        );
        assert_eq!(FixedDecimal::new(-1, 2).unwrap().to_string(), "-0.01");
        assert_eq!(
            FixedDecimal::new(i64::MIN, 18).unwrap().to_string(),
            "-9.223372036854775808"
        );
        assert_eq!(
            FixedDecimal::parse("9223372036854775807", 0)
                .unwrap()
                .representation(),
            i64::MAX
        );
        assert_eq!(
            FixedDecimal::parse("-9223372036854775808", 0)
                .unwrap()
                .representation(),
            i64::MIN
        );
        assert!(matches!(
            FixedDecimal::parse("1.005", 2),
            Err(DecimalError::ExcessPrecision { .. })
        ));
        assert_eq!(
            FixedDecimal::parse("001.20", 2).unwrap().to_string(),
            "1.20"
        );
    }

    #[test]
    fn decimal_arithmetic_is_checked_and_scale_safe() {
        let values = [350_000, -90_000, -2_350].map(|value| FixedDecimal::new(value, 2).unwrap());
        assert_eq!(
            FixedDecimal::checked_sum(values).unwrap().representation(),
            257_650
        );
        assert_eq!(
            FixedDecimal::new(1, 2)
                .unwrap()
                .checked_cmp(FixedDecimal::new(2, 2).unwrap())
                .unwrap(),
            Ordering::Less
        );
        assert!(matches!(
            FixedDecimal::new(1, 2)
                .unwrap()
                .checked_add(FixedDecimal::new(1, 3).unwrap()),
            Err(DecimalError::IncompatibleScale { .. })
        ));
        assert_eq!(
            FixedDecimal::new(i64::MAX, 0)
                .unwrap()
                .checked_add(FixedDecimal::new(1, 0).unwrap()),
            Err(DecimalError::Overflow)
        );
    }

    #[test]
    fn field_values_round_trip_without_floats() {
        let values = vec![
            FieldValue::Null,
            FieldValue::Text("x".into()),
            FieldValue::Integer(-1),
            FieldValue::FixedDecimal(-2350),
            FieldValue::Boolean(true),
            FieldValue::Date(-1),
            FieldValue::DateTime(0),
            FieldValue::Duration(-500),
            FieldValue::Enum(EnumOptionId::new()),
        ];
        for value in values {
            let encoded = serde_json::to_string(&value).unwrap();
            assert_eq!(serde_json::from_str::<FieldValue>(&encoded).unwrap(), value);
        }
    }
}
