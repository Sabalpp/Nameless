export const SIDEBAR_WIDTH = 280;
export const INSPECTOR_WIDTH = 300;
export const COLLAPSED_RAIL_WIDTH = 36;

export const SF_BG = '#C3C4CA';
export const SF_INK = 'rgba(0,0,0,0.85)';
export const SF_MUTED = 'rgba(0,0,0,0.55)';
export const SF_LINE = 'rgba(0,0,0,0.13)';
export const SF_ACCENT = 'rgba(0,0,0,0.72)';
export const SF_SUCCESS = '#1a5c38';
export const SF_DANGER = '#8b1a12';

export const CELL_STYLE = {
  fontFamily: "'Courier New', monospace",
  background: SF_BG,
  border: `1px solid ${SF_LINE}`,
  display: 'flex',
  alignItems: 'center',
  justifyContent: 'center',
  height: 32,
  lineHeight: 1,
};

export const PANEL_SECTION_TITLE = {
  padding: '10px 14px 6px',
  fontFamily: "'Courier New', monospace",
  fontSize: 10,
  fontWeight: 700,
  letterSpacing: '0.1em',
  textTransform: 'uppercase',
  color: SF_MUTED,
  whiteSpace: 'nowrap',
};

export const PANEL_ROW = {
  display: 'grid',
  gridTemplateColumns: '86px 1fr',
  gap: 8,
  padding: '3px 14px',
  fontFamily: "'Courier New', monospace",
  fontSize: 13,
  lineHeight: 1.35,
  color: SF_INK,
};

export const PANEL_LABEL = {
  color: SF_MUTED,
  textTransform: 'uppercase',
  overflow: 'hidden',
  textOverflow: 'ellipsis',
  whiteSpace: 'nowrap',
  fontSize: 10,
};

export const PANEL_VALUE = {
  overflow: 'hidden',
  textOverflow: 'ellipsis',
  whiteSpace: 'nowrap',
  color: SF_INK,
};

export const PANEL_WRAPPED_VALUE = {
  overflow: 'visible',
  textOverflow: 'clip',
  whiteSpace: 'normal',
  overflowWrap: 'anywhere',
  wordBreak: 'normal',
};

export const PANEL_HEADER_STYLE = {
  padding: '10px 14px 8px',
  fontFamily: "'Courier New', monospace",
  fontSize: 10,
  fontWeight: 700,
  letterSpacing: '0.12em',
  textTransform: 'uppercase',
  color: SF_MUTED,
  whiteSpace: 'nowrap',
  borderBottom: '1px solid rgba(0,0,0,0.08)',
};

export const PANEL_SECTION_DIVIDER = {
  borderTop: '1px solid rgba(0,0,0,0.10)',
  paddingTop: 8,
};

export const SPINE_STEP_TITLE = {
  padding: '12px 14px 6px',
  fontFamily: "'Courier New', monospace",
  fontSize: 10,
  fontWeight: 700,
  letterSpacing: '0.12em',
  textTransform: 'uppercase',
  color: SF_MUTED,
  whiteSpace: 'nowrap',
};

export const COACH_TEXT = {
  padding: '0 14px 10px',
  fontFamily: "'Courier New', monospace",
  fontSize: 12,
  lineHeight: 1.45,
  color: SF_MUTED,
};

export const MISSION_SUMMARY = {
  padding: '8px 14px 10px',
  fontFamily: "'Courier New', monospace",
  fontSize: 12,
  lineHeight: 1.4,
  color: SF_INK,
  borderTop: '1px solid rgba(0,0,0,0.08)',
};

export const MISSION_SUMMARY_SUB = {
  marginTop: 3,
  fontSize: 11,
  color: SF_MUTED,
  textTransform: 'uppercase',
  letterSpacing: '0.06em',
};

export const NARRATIVE_BLOCK = {
  padding: '6px 14px 10px',
  fontFamily: "'Courier New', monospace",
  fontSize: 13,
  lineHeight: 1.45,
  color: SF_INK,
};

export const NARRATIVE_LABEL = {
  fontSize: 10,
  fontWeight: 700,
  letterSpacing: '0.1em',
  textTransform: 'uppercase',
  color: SF_MUTED,
  marginBottom: 4,
};

const LIST_ITEM_BASE = {
  padding: '8px 14px',
  fontFamily: "'Courier New', monospace",
  fontSize: 13,
  letterSpacing: '0.02em',
  cursor: 'pointer',
  borderBottom: '1px solid rgba(0,0,0,0.06)',
  borderLeft: '2px solid transparent',
};

export const EMPTY_STATE = {
  padding: '7px 14px',
  fontFamily: "'Courier New', monospace",
  fontSize: 12,
  lineHeight: 1.45,
  color: SF_MUTED,
};

export function list_item_style(isSelected) {
  return {
    ...LIST_ITEM_BASE,
    color: isSelected ? SF_INK : SF_MUTED,
    background: isSelected ? 'rgba(0,0,0,0.06)' : 'transparent',
    borderLeft: isSelected ? `2px solid ${SF_ACCENT}` : '2px solid transparent',
  };
}

export function status_color(status) {
  if (status === 'survived' || status === 'SUCCESS') {
    return SF_SUCCESS;
  }
  if (status === 'failed') {
    return SF_DANGER;
  }
  return SF_MUTED;
}
