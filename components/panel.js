export const SIDEBAR_WIDTH = 280;
export const INSPECTOR_WIDTH = 300;
export const COLLAPSED_RAIL_WIDTH = 36;

export const CELL_STYLE = {
  fontFamily: "'Courier New', monospace",
  background: '#C3C4CA',
  border: '1px solid rgba(0,0,0,0.13)',
  display: 'flex',
  alignItems: 'center',
  justifyContent: 'center',
  height: 28,
  lineHeight: 1,
};

export const PANEL_SECTION_TITLE = {
  padding: '10px 14px 6px',
  fontFamily: "'Courier New', monospace",
  fontSize: 10,
  fontWeight: 700,
  letterSpacing: '0.12em',
  textTransform: 'uppercase',
  color: 'rgba(0,0,0,0.55)',
  whiteSpace: 'nowrap',
};

export const PANEL_ROW = {
  display: 'grid',
  gridTemplateColumns: '86px 1fr',
  gap: 8,
  padding: '3px 14px',
  fontFamily: "'Courier New', monospace",
  fontSize: 12,
  lineHeight: 1.25,
  color: 'rgba(0,0,0,0.85)',
};

export const PANEL_LABEL = {
  color: 'rgba(0,0,0,0.55)',
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
  color: 'rgba(0,0,0,0.85)',
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
  color: 'rgba(0,0,0,0.55)',
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
  letterSpacing: '0.14em',
  textTransform: 'uppercase',
  color: 'rgba(0,0,0,0.55)',
  whiteSpace: 'nowrap',
};

const LIST_ITEM_BASE = {
  padding: '7px 14px',
  fontFamily: "'Courier New', monospace",
  fontSize: 12,
  letterSpacing: '0.02em',
  cursor: 'pointer',
  borderBottom: '1px solid rgba(0,0,0,0.06)',
  borderLeft: '2px solid transparent',
};

export const EMPTY_STATE = {
  padding: '7px 14px',
  fontFamily: "'Courier New', monospace",
  fontSize: 12,
  lineHeight: 1.35,
  color: 'rgba(0,0,0,0.55)',
};

export function list_item_style(isSelected) {
  return {
    ...LIST_ITEM_BASE,
    color: isSelected ? 'rgba(0,0,0,0.85)' : 'rgba(0,0,0,0.55)',
    background: isSelected ? 'rgba(0,0,0,0.06)' : 'transparent',
    borderLeft: isSelected ? '2px solid rgba(0,0,0,0.55)' : '2px solid transparent',
  };
}
