import React, { useState, useEffect, useCallback, useMemo, useRef } from 'react';
import HullDiagram from './components/HullDiagram.jsx';
import { MISSIONS } from './missions.js';
import {
  PANEL_LABEL,
  PANEL_ROW,
  PANEL_VALUE,
  PANEL_WRAPPED_VALUE,
  SF_BG,
} from './components/panel.js';

const TICK_STEP_MS = 1000;
const MIN_STEP_SPEED = 1;
const MAX_STEP_SPEED = 64;

function fmtNumber(value, digits = 1, fallback = '—') {
  return Number.isFinite(value) ? value.toFixed(digits) : fallback;
}

function fmtRange(range, unit = '', digits = 1) {
  if (!range) return '—';
  const parts = [];
  if (Number.isFinite(range.avg)) parts.push(`avg ${fmtNumber(range.avg, digits)}${unit}`);
  if (Number.isFinite(range.min)) parts.push(`min ${fmtNumber(range.min, digits)}${unit}`);
  if (Number.isFinite(range.max)) parts.push(`max ${fmtNumber(range.max, digits)}${unit}`);
  return parts.length ? parts.join(' / ') : '—';
}

function missionFactor(value) {
  if (value === null || value === undefined || value === '' || value === '—') return 'none';
  if (typeof value === 'number' && value === 0) return 'none';
  if (typeof value === 'string' && /^0(?:\.0+)?(?:\s*(?:%|m\/s|ppt|°C))?$/i.test(value.trim())) return 'none';
  return value;
}

function formatFailureDetail(failure) {
  const detail = failure?.detail;
  if (!detail) return failure?.mode ?? '—';
  const zone = detail.failed_zone ?? 'Component';
  const metric = detail.failed_metric ?? failure?.mode ?? 'failure';
  const value = detail.failed_value ?? 'failed';
  return `${zone} ${metric} ${value}`;
}

function displayStatus(status) {
  return status === 'survived' ? 'SUCCESS' : status;
}

function makeCampaignRunId(missionId) {
  const safeMission = String(missionId ?? 'campaign').replace(/[^A-Za-z0-9_-]/g, '_');
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  return `${safeMission}_${stamp}`;
}

function responseErrorMessage(data, fallback) {
  const details = [data?.error, data?.stderr, data?.stdout]
    .filter(Boolean)
    .join('\n');
  return details || fallback;
}

function formatElapsedDayLabel(elapsedH) {
  const safeElapsedH = Math.max(0, Number(elapsedH) || 0);
  const day = Math.floor(safeElapsedH / 24);
  const hour = Math.floor(safeElapsedH % 24);
  return `Day ${day} ${String(hour).padStart(2, '0')}h`;
}

function sortCampaignsByCreatedAt(campaigns) {
  return [...campaigns].sort((a, b) => {
    const bTime = Date.parse(b.created_at);
    const aTime = Date.parse(a.created_at);
    if (Number.isFinite(bTime) && Number.isFinite(aTime) && bTime !== aTime) {
      return bTime - aTime;
    }
    return b.id.localeCompare(a.id);
  });
}

let cachedLandPolygons = null;

function pointInRing(lon, lat, ring) {
  let inside = false;
  for (let index = 0, prior = ring.length - 1; index < ring.length; prior = index, index += 1) {
    const [x, y] = ring[index];
    const [priorX, priorY] = ring[prior];
    if (((y > lat) !== (priorY > lat))
      && lon < ((priorX - x) * (lat - y)) / (priorY - y + Number.EPSILON) + x) {
      inside = !inside;
    }
  }
  return inside;
}

function buildLandPolygons(geoJson) {
  const polygons = [];
  geoJson.features.forEach((feature) => {
    const geometry = feature.geometry;
    const groups = geometry?.type === 'Polygon'
      ? [geometry.coordinates]
      : geometry?.type === 'MultiPolygon'
        ? geometry.coordinates
        : [];
    groups.forEach((rings) => {
      const outer = rings[0];
      const longitudes = outer.map((point) => point[0]);
      const latitudes = outer.map((point) => point[1]);
      polygons.push({
        rings,
        minLon: Math.min(...longitudes),
        maxLon: Math.max(...longitudes),
        minLat: Math.min(...latitudes),
        maxLat: Math.max(...latitudes),
      });
    });
  });
  return polygons;
}

function isLand(lon, lat, polygons) {
  const normalizedLon = ((lon + 180) % 360 + 360) % 360 - 180;
  return polygons.some((polygon) => (
    normalizedLon >= polygon.minLon
    && normalizedLon <= polygon.maxLon
    && lat >= polygon.minLat
    && lat <= polygon.maxLat
    && pointInRing(normalizedLon, lat, polygon.rings[0])
    && !polygon.rings.slice(1).some((hole) => pointInRing(normalizedLon, lat, hole))
  ));
}

function legCrossesLand(origin, destination, polygons) {
  let endLon = destination.lon_deg;
  while (endLon - origin.lon_deg > 180) endLon -= 360;
  while (endLon - origin.lon_deg < -180) endLon += 360;
  // Coastal clicks can resolve a few pixels inland on the low-resolution
  // country mask. Ignore the endpoint margins so they do not force an
  // ocean-scale detour just to approach or leave a port.
  for (let step = 4; step < 97; step += 1) {
    const ratio = step / 100;
    if (isLand(
      origin.lon_deg + (endLon - origin.lon_deg) * ratio,
      origin.lat_deg + (destination.lat_deg - origin.lat_deg) * ratio,
      polygons,
    )) return true;
  }
  return false;
}

async function planWaterWaypoints(origin, destination) {
  if (!cachedLandPolygons) {
    const response = await fetch('/ne_110m_admin_0_countries.geojson');
    if (!response.ok) throw new Error('Could not load the land map');
    cachedLandPolygons = buildLandPolygons(await response.json());
  }
  const polygons = cachedLandPolygons;
  if (!legCrossesLand(origin, destination, polygons)) return [];

  let destinationLon = destination.lon_deg;
  while (destinationLon - origin.lon_deg > 180) destinationLon -= 360;
  while (destinationLon - origin.lon_deg < -180) destinationLon += 360;
  const resolution = 1.5;
  const minLat = Math.max(-78, Math.min(origin.lat_deg, destination.lat_deg) - 20);
  const maxLat = Math.min(78, Math.max(origin.lat_deg, destination.lat_deg) + 20);
  const minLon = Math.min(origin.lon_deg, destinationLon) - 28;
  const maxLon = Math.max(origin.lon_deg, destinationLon) + 28;
  const rows = Math.floor((maxLat - minLat) / resolution) + 1;
  const columns = Math.floor((maxLon - minLon) / resolution) + 1;
  const cellFor = (point, lon = point.lon_deg) => [
    Math.round((point.lat_deg - minLat) / resolution),
    Math.round((lon - minLon) / resolution),
  ];
  const start = cellFor(origin);
  const end = cellFor(destination, destinationLon);
  const keyOf = ([row, column]) => `${row}:${column}`;
  const queue = [start];
  const parents = new Map();
  const visited = new Set([keyOf(start)]);
  const directions = [
    [-1, -1], [-1, 0], [-1, 1], [0, -1],
    [0, 1], [1, -1], [1, 0], [1, 1],
  ];
  let cursor = 0;
  let found = false;
  while (cursor < queue.length && queue.length < 20000) {
    const current = queue[cursor++];
    if (keyOf(current) === keyOf(end)) {
      found = true;
      break;
    }
    directions.forEach(([rowDelta, columnDelta]) => {
      const next = [current[0] + rowDelta, current[1] + columnDelta];
      const key = keyOf(next);
      if (next[0] < 0 || next[0] >= rows || next[1] < 0 || next[1] >= columns || visited.has(key)) return;
      const lat = minLat + next[0] * resolution;
      const lon = minLon + next[1] * resolution;
      const nearEndpoint = Math.hypot(next[0] - start[0], next[1] - start[1]) <= 1.5
        || Math.hypot(next[0] - end[0], next[1] - end[1]) <= 1.5;
      if (!nearEndpoint && isLand(lon, lat, polygons)) return;
      visited.add(key);
      parents.set(key, current);
      queue.push(next);
    });
  }
  if (!found) throw new Error('No water-only route was found between those points');
  const cells = [];
  let current = end;
  while (keyOf(current) !== keyOf(start)) {
    cells.push(current);
    current = parents.get(keyOf(current));
  }
  cells.push(start);
  cells.reverse();
  const turns = [];
  for (let index = 1; index < cells.length - 1; index += 1) {
    const incoming = [cells[index][0] - cells[index - 1][0], cells[index][1] - cells[index - 1][1]];
    const outgoing = [cells[index + 1][0] - cells[index][0], cells[index + 1][1] - cells[index][1]];
    if (incoming[0] !== outgoing[0] || incoming[1] !== outgoing[1]) turns.push(cells[index]);
  }
  const selectedTurns = turns.length > 10
    ? turns.filter((_, index) => index % Math.ceil(turns.length / 10) === 0).slice(0, 10)
    : turns;
  return selectedTurns.map(([row, column], index) => ({
    name: `Water route node ${index + 1}`,
    lat_deg: minLat + row * resolution,
    lon_deg: ((minLon + column * resolution + 180) % 360 + 360) % 360 - 180,
  }));
}

function LearningMiniGraph({ iterations, selectedIndex, onSelect }) {
  if (!iterations.length) return null;
  const width = 380;
  const height = 190;
  const pad = { left: 42, right: 16, top: 16, bottom: 30 };
  const costs = iterations.map((item) => Number(item?.result?.cost_usd) || 0);
  let minCost = Math.min(...costs);
  let maxCost = Math.max(...costs);
  if (maxCost - minCost < 1) {
    minCost = Math.max(0, minCost - 500);
    maxCost += 500;
  }
  const points = iterations.map((item, index) => {
    const cost = Number(item?.result?.cost_usd) || minCost;
    const completion = Math.max(0, Math.min(100, Number(item?.result?.distance_pct) || 0));
    return {
      x: pad.left + ((cost - minCost) / (maxCost - minCost)) * (width - pad.left - pad.right),
      y: pad.top + (1 - completion / 100) * (height - pad.top - pad.bottom),
      survived: Boolean(item?.result?.survived),
      completion,
      index,
    };
  });

  return (
    <div style={{ marginTop: 12, borderTop: '1px solid rgba(0,0,0,0.12)', paddingTop: 9 }}>
      <div style={{ fontSize: 8, letterSpacing: '0.12em', color: 'rgba(0,0,0,0.38)', marginBottom: 4 }}>
        COST × VOYAGE COMPLETION
      </div>
      <svg width="100%" viewBox={`0 0 ${width} ${height}`} style={{ display: 'block' }}>
        {[0, 50, 100].map((percent) => {
          const y = pad.top + (1 - percent / 100) * (height - pad.top - pad.bottom);
          return (
            <g key={percent}>
              <line x1={pad.left} y1={y} x2={width - pad.right} y2={y} stroke="rgba(0,0,0,0.10)" strokeDasharray="2 5" />
              <text x={pad.left - 7} y={y + 3} textAnchor="end" fontSize="8" fill="rgba(0,0,0,0.42)">{percent}%</text>
            </g>
          );
        })}
        <line x1={pad.left} y1={pad.top} x2={pad.left} y2={height - pad.bottom} stroke="rgba(0,0,0,0.32)" />
        <line x1={pad.left} y1={height - pad.bottom} x2={width - pad.right} y2={height - pad.bottom} stroke="rgba(0,0,0,0.32)" />
        {points.slice(1).map((point, index) => (
          <line
            key={`edge-${index}`}
            x1={points[index].x}
            y1={points[index].y}
            x2={point.x}
            y2={point.y}
            stroke="rgba(0,0,0,0.28)"
            strokeWidth="1"
          />
        ))}
        {points.map((point) => (
          <g
            key={point.index}
            transform={`translate(${point.x} ${point.y})`}
            onClick={() => onSelect(point.index)}
            style={{ cursor: 'pointer' }}
          >
            {selectedIndex === point.index ? (
              <circle
                className="learning-node-glow learning-node-glow--active"
                r="10"
                fill="rgba(180,35,24,0.14)"
              />
            ) : null}
            <circle r="3.5" fill="#B42318" />
          </g>
        ))}
        <text x={pad.left} y={height - 10} fontSize="8" fill="rgba(0,0,0,0.40)">
          ${minCost.toFixed(0)}
        </text>
        <text x={width - pad.right} y={height - 10} textAnchor="end" fontSize="8" fill="rgba(0,0,0,0.40)">
          ${maxCost.toFixed(0)}
        </text>
      </svg>
    </div>
  );
}

function AgentSection({ title, summary, open, onToggle, children }) {
  return (
    <div style={{ borderTop: '1px solid rgba(0,0,0,0.10)' }}>
      <button
        type="button"
        onClick={onToggle}
        style={{
          width: '100%',
          padding: '9px 0',
          display: 'flex',
          alignItems: 'flex-start',
          justifyContent: 'space-between',
          gap: 10,
          background: 'transparent',
          border: 'none',
          cursor: 'pointer',
          fontFamily: "'Courier New', monospace",
          textAlign: 'left',
        }}
      >
        <span style={{
          fontSize: 10,
          fontWeight: 700,
          letterSpacing: '0.12em',
          textTransform: 'uppercase',
          color: 'rgba(0,0,0,0.55)',
          whiteSpace: 'nowrap',
        }}>
          {open ? '▼' : '▶'} {title}
        </span>
        {!open && summary ? (
          <span style={{
            fontSize: 9,
            color: 'rgba(0,0,0,0.42)',
            overflow: 'hidden',
            textOverflow: 'ellipsis',
            whiteSpace: 'nowrap',
            maxWidth: '58%',
          }}>
            {summary}
          </span>
        ) : null}
      </button>
      {open ? <div style={{ paddingBottom: 10 }}>{children}</div> : null}
    </div>
  );
}

export default function App() {
  const [simResult, setSimResult] = useState(null);
  const [loading, setLoading]     = useState(false);
  const [error, setError]         = useState(null);
  const [tickPosition, setTickPosition] = useState(0);
  const [stepSpeed, setStepSpeed] = useState(1);
  const [selectedMission, setSelectedMission] = useState(null);
  const [simulations, setSimulations] = useState([]);
  const [selectedCampaignId, setSelectedCampaignId] = useState(null);
  const [selectedSimulationId, setSelectedSimulationId] = useState(null);
  const [runningGemini, setRunningGemini] = useState(false);
  const [runningCampaignId, setRunningCampaignId] = useState(null);
  const [runningCampaignStartedAt, setRunningCampaignStartedAt] = useState(null);
  const [geminiDotCount, setGeminiDotCount] = useState(0);
  const [agentsOpen, setAgentsOpen] = useState(true);
  const [openSections, setOpenSections] = useState({
    missions: true,
    brief: false,
    campaigns: false,
    runs: false,
    analysis: false,
    params: false,
  });
  const toggleSection = (key) => {
    setOpenSections((current) => ({ ...current, [key]: !current[key] }));
  };
  const tickPositionRef = useRef(0);
  const stepSpeedRef = useRef(1);
  const heldDirectionRef = useRef(0);
  const frameRef = useRef(null);
  const lastFrameTimeRef = useRef(null);
  const stoppingGeminiRef = useRef(false);
  const agentSocketRef = useRef(null);
  const [pickedPoints, setPickedPoints] = useState([]);
  const [agentStatus, setAgentStatus] = useState('Click the globe to choose point A');
  const [agentIterations, setAgentIterations] = useState(0);
  const [learningIterations, setLearningIterations] = useState([]);
  const [hasStartedPointRun, setHasStartedPointRun] = useState(false);
  const [liveShipProgress, setLiveShipProgress] = useState(0);
  const [activeAttemptIndex, setActiveAttemptIndex] = useState(null);
  const [plannedWaypoints, setPlannedWaypoints] = useState([]);

  const runPointSimulation = useCallback(async (origin, destination) => {
    if (agentSocketRef.current?.readyState < 2) {
      agentSocketRef.current.close();
    }
    setRunningGemini(true);
    setAgentIterations(0);
    setLearningIterations([]);
    setHasStartedPointRun(true);
    setLiveShipProgress(0);
    setActiveAttemptIndex(null);
    setAgentStatus('Checking route against land map…');
    setError(null);
    let waterWaypoints;
    try {
      waterWaypoints = await planWaterWaypoints(origin, destination);
      setPlannedWaypoints(waterWaypoints);
    } catch (routeError) {
      setRunningGemini(false);
      setAgentStatus(routeError.message);
      setError(routeError.message);
      return;
    }
    setAgentStatus('Connecting to Jac walker…');
    const jacSocketUrl = new URL('/ws/StreamOptimizeFromPoints', window.location.href);
    jacSocketUrl.protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
    jacSocketUrl.port = '8016';
    const socket = new WebSocket(jacSocketUrl);
    let receivedReportBatch = false;
    agentSocketRef.current = socket;
    socket.onopen = () => {
      setAgentStatus('Running mission optimizer…');
      socket.send(JSON.stringify({
        origin: { name: 'Point A', ...origin },
        destination: { name: 'Point B', ...destination },
        name: `Point A to Point B ${Date.now()}`,
        route_iterations: 1,
        material_iterations: 20,
        route_waypoints: waterWaypoints,
        use_codex: true,
        codex_timeout_s: 30,
        use_live_conditions: false,
        save_simulation: true,
        stream_events: true,
      }));
    };
    socket.onmessage = (message) => {
      try {
        const envelope = JSON.parse(message.data);
        const reports = envelope?.data?.reports ?? [];
        receivedReportBatch = reports.length > 0;
        reports.forEach((report, index) => {
          window.setTimeout(() => {
            if (report.event_type === 'progress' || report.event_type === 'complete') {
              setAgentStatus(report.message ?? report.status ?? 'Working…');
            }
            if (report.event_type === 'iteration') {
              if (report.phase === 'material_search') {
                setAgentIterations((count) => count + 1);
                setLearningIterations((current) => {
                  const next = [...current, report.iteration];
                  setActiveAttemptIndex(next.length - 1);
                  return next;
                });
                setLiveShipProgress(Math.max(
                  0,
                  Math.min(1, Number(report.iteration?.result?.distance_pct ?? 0) / 100),
                ));
              }
              setAgentStatus(`${report.phase?.replaceAll('_', ' ') ?? 'Iteration'} ${report.completed} of ${report.total}`);
            }
            if (report.event_type === 'complete') {
              setLearningIterations((current) => {
                const survivors = current
                  .map((attempt, attemptIndex) => ({ attempt, attemptIndex }))
                  .filter(({ attempt }) => attempt?.result?.survived)
                  .sort((a, b) => (
                    Number(a.attempt?.result?.cost_usd ?? Infinity)
                    - Number(b.attempt?.result?.cost_usd ?? Infinity)
                  ));
                if (survivors.length > 0) {
                  const best = survivors[0];
                  setActiveAttemptIndex(best.attemptIndex);
                  setLiveShipProgress(1);
                }
                return current;
              });
              setRunningGemini(false);
            }
          }, index * 350);
        });
      } catch (eventError) {
        setError(eventError.message);
      }
    };
    socket.onerror = () => {
      setRunningGemini(false);
      setAgentStatus(`Could not connect to Jac at ${jacSocketUrl.host}`);
    };
    socket.onclose = () => {
      if (!receivedReportBatch) {
        setRunningGemini(false);
        setAgentStatus('Jac disconnected before returning simulation data');
      }
    };
  }, []);

  const pickGlobePoint = useCallback((point) => {
    if (hasStartedPointRun) return;
    setPickedPoints((current) => {
      if (current.length >= 2) {
        setAgentStatus('Point A selected — click point B');
        return [point];
      }
      const next = [...current, point];
      if (next.length === 1) {
        setAgentStatus('Point A selected — click point B');
      } else {
        setAgentStatus('Points selected — press Run Agent');
      }
      return next;
    });
  }, [hasStartedPointRun]);
  const activeLearningAttempt = activeAttemptIndex === null
    ? null
    : learningIterations[activeAttemptIndex] ?? null;
  const activeAttemptPath = Array.isArray(activeLearningAttempt?.path)
    ? activeLearningAttempt.path
    : [];
  const visualRoute = activeAttemptPath.length >= 2
    ? {
      origin: activeAttemptPath[0],
      waypoints: activeAttemptPath.slice(1, -1),
      destination: activeAttemptPath.at(-1),
    }
    : pickedPoints.length === 2
      ? { origin: pickedPoints[0], waypoints: plannedWaypoints, destination: pickedPoints[1] }
      : null;
  const visualFailureZone = activeLearningAttempt?.result?.failure_zone ?? '';
  const visualTick = activeLearningAttempt
    ? {
      failure: activeLearningAttempt.result?.survived ? null : {
        mode: activeLearningAttempt.result?.failure_mode,
      },
      zones: visualFailureZone
        ? [{ zone: visualFailureZone, fatigue_consumed: 1 }]
        : [],
    }
    : null;

  const setDisplayedTickPosition = useCallback((nextPosition) => {
    tickPositionRef.current = nextPosition;
    setTickPosition(nextPosition);
  }, []);

  const setDisplayedStepSpeed = useCallback((nextSpeed) => {
    stepSpeedRef.current = nextSpeed;
    setStepSpeed(nextSpeed);
  }, []);

  const refreshSimulations = useCallback(() => {
    fetch('/api/simulations')
      .then(r => r.ok ? r.json() : Promise.reject(new Error(`HTTP ${r.status}`)))
      .then(data => setSimulations(Array.isArray(data.simulations) ? data.simulations : []))
      .catch(() => setSimulations([]));
  }, []);

  const refreshGeminiStatus = useCallback(() => (
    fetch('/api/gemini/status')
      .then(r => r.ok ? r.json() : Promise.reject(new Error(`HTTP ${r.status}`)))
      .then((status) => {
        if (status?.active && status.run_id) {
          setRunningGemini(true);
          setRunningCampaignId(status.run_id);
          setRunningCampaignStartedAt(status.started_at ?? status.run_id);
          setSelectedCampaignId((current) => current ?? status.run_id);
          setLoading(true);
          return status;
        }
        setRunningGemini(false);
        setRunningCampaignId(null);
        setRunningCampaignStartedAt(null);
        setLoading(false);
        return status;
      })
      .catch(() => null)
  ), []);

  const campaigns = useMemo(() => {
    const byId = new Map();
    simulations.forEach((sim) => {
      if (!sim.run_id) return;
      const existing = byId.get(sim.run_id);
      byId.set(sim.run_id, {
        id: sim.run_id,
        created_at: existing?.created_at ?? sim.created_at,
        count: (existing?.count ?? 0) + 1,
      });
    });
    return sortCampaignsByCreatedAt(byId.values());
  }, [simulations]);
  const visibleCampaigns = useMemo(() => {
    if (!runningCampaignId || campaigns.some((campaign) => campaign.id === runningCampaignId)) {
      return campaigns;
    }
    return sortCampaignsByCreatedAt([
      { id: runningCampaignId, created_at: runningCampaignStartedAt ?? runningCampaignId, count: 0 },
      ...campaigns,
    ]);
  }, [campaigns, runningCampaignId, runningCampaignStartedAt]);

  useEffect(() => {
    refreshSimulations();
    refreshGeminiStatus();
  }, [refreshGeminiStatus, refreshSimulations]);

  useEffect(() => {
    if (visibleCampaigns.length === 0) {
      if (selectedCampaignId !== null && selectedCampaignId !== runningCampaignId) setSelectedCampaignId(null);
      return;
    }
    if (
      !selectedCampaignId
      || (
        !visibleCampaigns.some((campaign) => campaign.id === selectedCampaignId)
        && selectedCampaignId !== runningCampaignId
      )
    ) {
      setSelectedCampaignId(visibleCampaigns[0].id);
    }
  }, [runningCampaignId, selectedCampaignId, visibleCampaigns]);

  useEffect(() => {
    if (!runningGemini) return undefined;
    refreshSimulations();
    const id = window.setInterval(refreshSimulations, 1500);
    return () => window.clearInterval(id);
  }, [refreshSimulations, runningGemini]);

  useEffect(() => {
    if (!runningGemini) return undefined;
    const id = window.setInterval(() => {
      refreshGeminiStatus().then((status) => {
        if (!status?.active) refreshSimulations();
      });
    }, 1500);
    return () => window.clearInterval(id);
  }, [refreshGeminiStatus, refreshSimulations, runningGemini]);

  useEffect(() => {
    if (!runningGemini) {
      setGeminiDotCount(0);
      return undefined;
    }
    const id = window.setInterval(() => {
      setGeminiDotCount((count) => (count + 1) % 4);
    }, 300);
    return () => window.clearInterval(id);
  }, [runningGemini]);

  useEffect(() => {
    if (!selectedMission) {
      if (!selectedSimulationId) {
        setSimResult(null);
      }
      setError(null);
      return;
    }
    setError(null);
    setSimResult(null);
    setSelectedSimulationId(null);
    setLoading(false);
  }, [selectedMission, selectedSimulationId]);

  const loadSavedSimulation = useCallback((id) => {
    setLoading(true);
    setError(null);
    fetch(`/api/simulation?id=${encodeURIComponent(id)}`)
      .then(r => {
        if (!r.ok) return r.json().then(d => Promise.reject(new Error(responseErrorMessage(d, `HTTP ${r.status}`))));
        return r.json();
      })
      .then(data => {
        setSelectedMission(null);
        setSelectedSimulationId(id);
        setSimResult(data.result);
        setLoading(false);
      })
      .catch(e => {
        setError(e.message);
        setLoading(false);
      });
  }, []);

  const runGeminiSimulations = useCallback(() => {
    if (!selectedMission) {
      setError('Select a mission brief before running the agent.');
      return;
    }
    stoppingGeminiRef.current = false;
    setRunningGemini(true);
    setGeminiDotCount(0);
    setLoading(true);
    setError(null);
    setSelectedSimulationId(null);
    const runId = makeCampaignRunId(selectedMission.id);
    const startedAt = new Date().toISOString();
    setRunningCampaignId(runId);
    setRunningCampaignStartedAt(startedAt);
    setSelectedCampaignId(runId);
    fetch('/api/gemini/run', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ mission_id: selectedMission.id, tier: 'lowest', run_id: runId }),
    })
      .then(r => {
        if (!r.ok) return r.json().then(d => Promise.reject(new Error(responseErrorMessage(d, `HTTP ${r.status}`))));
        return r.json();
      })
      .then(manifest => {
        if (manifest?.run_id) {
          setSelectedCampaignId(manifest.run_id);
        }
        refreshSimulations();
        const bestSurvivor = manifest.best_survivor;
        const last = Array.isArray(manifest.iterations) ? manifest.iterations.at(-1) : null;
        const simulationToLoad = bestSurvivor?.id ? bestSurvivor : last;
        if (simulationToLoad?.id) {
          loadSavedSimulation(simulationToLoad.id);
        } else {
          setLoading(false);
        }
      })
      .catch(e => {
        if (!stoppingGeminiRef.current) {
          setError(e.message);
        }
        setLoading(false);
      })
      .finally(() => {
        stoppingGeminiRef.current = false;
        setRunningGemini(false);
        setRunningCampaignId(null);
        setRunningCampaignStartedAt(null);
      });
  }, [loadSavedSimulation, refreshSimulations, selectedMission]);

  const stopGeminiSimulations = useCallback(() => {
    stoppingGeminiRef.current = true;
    fetch('/api/gemini/stop', { method: 'POST' })
      .then(() => {
        setRunningGemini(false);
        setRunningCampaignId(null);
        setRunningCampaignStartedAt(null);
        setLoading(false);
        refreshSimulations();
      })
      .catch(e => {
        setError(e.message);
      });
  }, [refreshSimulations]);

  const selectCampaign = useCallback((campaignId) => {
    setSelectedCampaignId(campaignId);
    setSelectedSimulationId(null);
    setSimResult(null);
  }, []);

  useEffect(() => {
    heldDirectionRef.current = 0;
    lastFrameTimeRef.current = null;
    if (frameRef.current) {
      window.cancelAnimationFrame(frameRef.current);
      frameRef.current = null;
    }
    setDisplayedTickPosition(0);
  }, [setDisplayedTickPosition, simResult]);

  const ticks = Array.isArray(simResult?.ticks) ? simResult.ticks : [];
  const tickCount = ticks.length;
  const isViewingSimulation = Boolean(simResult) && tickCount > 0;
  const completedDistanceNm = simResult?.result?.distance_completed_nm;
  const completedPct = simResult?.result?.distance_completed_pct;
  const totalDistanceFromPct = completedDistanceNm > 0 && completedPct > 0
    ? completedDistanceNm / (completedPct / 100)
    : null;
  const totalDistanceNm = totalDistanceFromPct
    ?? completedDistanceNm
    ?? ticks[tickCount - 1]?.distance_completed_nm
    ?? 0;
  const finalTickDistanceNm = ticks[tickCount - 1]?.distance_completed_nm ?? 0;
  const simulationFailed = simResult?.status === 'failed' || Boolean(simResult?.failure);
  const needsSyntheticDestinationTicks = tickCount > 0
    && !simulationFailed
    && totalDistanceNm > 0
    && finalTickDistanceNm < totalDistanceNm * 0.995;
  const averageTickDistanceNm = tickCount > 1
    ? Math.max(finalTickDistanceNm / (tickCount - 1), totalDistanceNm / 120, 1)
    : Math.max(totalDistanceNm / 120, 1);
  const syntheticDestinationTickCount = needsSyntheticDestinationTicks
    ? Math.max(1, Math.ceil((totalDistanceNm - finalTickDistanceNm) / averageTickDistanceNm))
    : 0;
  const playbackTickCount = tickCount + syntheticDestinationTickCount;
  const playbackMaxPosition = Math.max(0, playbackTickCount - 1);
  const clampedTickPosition = tickCount > 0
    ? Math.max(0, Math.min(tickPosition, playbackMaxPosition))
    : 0;
  const activeTickIndex = tickCount > 0
    ? Math.max(0, Math.min(tickCount - 1, Math.round(clampedTickPosition)))
    : 0;
  const activeTick = tickCount > 0 ? ticks[activeTickIndex] : null;
  const interpolatedElapsedH = (() => {
    if (tickCount <= 0) return 0;
    const averageElapsedPerTickH = tickCount > 1
      ? Number(ticks[tickCount - 1]?.elapsed_h ?? 0) / (tickCount - 1)
      : 1;
    const elapsedAt = (index) => {
      if (index >= tickCount) {
        return Number(ticks[tickCount - 1]?.elapsed_h ?? 0)
          + (index - tickCount + 1) * averageElapsedPerTickH;
      }
      return Number(ticks[Math.max(0, index)]?.elapsed_h ?? 0);
    };
    const fromIndex = Math.floor(clampedTickPosition);
    const toIndex = Math.min(playbackTickCount - 1, fromIndex + 1);
    const t = clampedTickPosition - fromIndex;
    const fromElapsed = elapsedAt(fromIndex);
    const toElapsed = elapsedAt(toIndex);
    return fromElapsed + (toElapsed - fromElapsed) * t;
  })();
  const activeDayLabel = formatElapsedDayLabel(interpolatedElapsedH);
  const activeRouteSegment = simResult?.voyage?.route_segments?.[activeTick?.segment_index ?? 0] ?? null;
  const activeConditions = activeRouteSegment?.conditions ?? null;
  const config = simResult?.configuration ?? null;
  const displayedZones = config?.zones ?? [];
  const failureDetail = formatFailureDetail(simResult?.failure);
  const selectedSimulation = simulations.find((sim) => sim.id === selectedSimulationId) ?? null;
  const visibleSimulations = selectedCampaignId
    ? simulations.filter((sim) => sim.run_id === selectedCampaignId)
    : simulations;
  const selectedCampaign = visibleCampaigns.find((campaign) => campaign.id === selectedCampaignId) ?? null;
  const selectedCampaignStatus = selectedCampaign?.id && runningCampaignId === selectedCampaign.id
    ? 'running'
    : 'ended';
  const campaignMissionId = visibleSimulations.find((sim) => sim.params?.id)?.params?.id ?? null;
  const campaignMission = MISSIONS.find((mission) => mission.id === campaignMissionId) ?? null;
  const missionBrief = selectedMission;
  const env = missionBrief?.environmental_profile ?? null;
  const campaignSuccessCount = visibleSimulations.filter((sim) => sim.status === 'survived').length;
  const campaignFailureCount = visibleSimulations.filter((sim) => sim.status === 'failed').length;
  const latestCampaignSimulation = [...visibleSimulations]
    .sort((a, b) => b.iteration - a.iteration)[0] ?? null;
  const bestSimulation = (() => {
    const costOf = (sim) => Number(sim?.result?.total_config_cost_usd);
    const survivors = visibleSimulations
      .filter((sim) => sim.status === 'survived')
      .sort((a, b) => {
        const costDelta = (Number.isFinite(costOf(a)) ? costOf(a) : Infinity)
          - (Number.isFinite(costOf(b)) ? costOf(b) : Infinity);
        if (costDelta !== 0) return costDelta;
        return (b.eval?.score_pct ?? 0) - (a.eval?.score_pct ?? 0);
      });
    if (survivors.length > 0) return survivors[0];
    return [...visibleSimulations].sort((a, b) => (b.eval?.score_pct ?? 0) - (a.eval?.score_pct ?? 0))[0] ?? null;
  })();
  const bestSimulationLabel = bestSimulation
    ? `${String(bestSimulation.iteration).padStart(2, '0')} (${Number.isFinite(bestSimulation.eval?.score_pct) ? `${bestSimulation.eval.score_pct}%` : '—'} / ${Number.isFinite(bestSimulation.result?.total_config_cost_usd) ? `$${bestSimulation.result.total_config_cost_usd.toLocaleString('en-US', { maximumFractionDigits: 0 })}` : '—'})`
    : null;
  const tickProgress = (() => {
    if (playbackTickCount <= 0 || totalDistanceNm <= 0) {
      return Math.min((simResult?.result?.distance_completed_pct ?? 0) / 100, 1);
    }

    const fromIndex = Math.floor(clampedTickPosition);
    const toIndex = Math.min(playbackTickCount - 1, fromIndex + 1);
    const t = clampedTickPosition - fromIndex;
    const distanceAt = (index) => (
      index >= tickCount
        ? finalTickDistanceNm
          + (totalDistanceNm - finalTickDistanceNm)
            * Math.min((index - tickCount + 1) / syntheticDestinationTickCount, 1)
        : (ticks[index]?.distance_completed_nm ?? 0)
    );
    const fromDistance = distanceAt(fromIndex);
    const toDistance = distanceAt(toIndex);
    return Math.min((fromDistance + (toDistance - fromDistance) * t) / totalDistanceNm, 1);
  })();

  useEffect(() => {
    const stopHeldStep = () => {
      heldDirectionRef.current = 0;
      lastFrameTimeRef.current = null;
      if (frameRef.current) {
        window.cancelAnimationFrame(frameRef.current);
        frameRef.current = null;
      }
    };

    const stepFrame = (now) => {
      const direction = heldDirectionRef.current;
      if (!direction || !isViewingSimulation || playbackTickCount <= 1) {
        stopHeldStep();
        return;
      }

      const previousTime = lastFrameTimeRef.current ?? now;
      lastFrameTimeRef.current = now;
      const deltaTicks = ((now - previousTime) / TICK_STEP_MS) * stepSpeedRef.current;
      const nextPosition = Math.max(
        0,
        Math.min(playbackMaxPosition, tickPositionRef.current + direction * deltaTicks),
      );
      setDisplayedTickPosition(nextPosition);

      if (
        (direction > 0 && nextPosition >= playbackMaxPosition)
        || (direction < 0 && nextPosition <= 0)
      ) {
        stopHeldStep();
        return;
      }

      frameRef.current = window.requestAnimationFrame(stepFrame);
    };

    const startHeldStep = (direction) => {
      if (!isViewingSimulation || playbackTickCount <= 1) return;
      if (heldDirectionRef.current === direction) return;
      stopHeldStep();
      heldDirectionRef.current = direction;
      lastFrameTimeRef.current = null;
      frameRef.current = window.requestAnimationFrame(stepFrame);
    };

    const onKeyDown = (event) => {
      const target = event.target;
      const isEditable = target instanceof HTMLElement && (
        target.isContentEditable
        || target.tagName === 'INPUT'
        || target.tagName === 'TEXTAREA'
        || target.tagName === 'SELECT'
      );
      if (isEditable) return;

      if (event.code === 'ArrowRight') {
        event.preventDefault();
        startHeldStep(1);
      } else if (event.code === 'ArrowLeft') {
        event.preventDefault();
        startHeldStep(-1);
      } else if (event.code === 'ArrowUp') {
        event.preventDefault();
        setDisplayedStepSpeed(Math.min(MAX_STEP_SPEED, stepSpeedRef.current * 2));
      } else if (event.code === 'ArrowDown') {
        event.preventDefault();
        setDisplayedStepSpeed(Math.max(MIN_STEP_SPEED, stepSpeedRef.current / 2));
      }
    };

    const onKeyUp = (event) => {
      if (
        (event.code === 'ArrowRight' && heldDirectionRef.current > 0)
        || (event.code === 'ArrowLeft' && heldDirectionRef.current < 0)
      ) {
        stopHeldStep();
      }
    };

    window.addEventListener('keydown', onKeyDown);
    window.addEventListener('keyup', onKeyUp);
    window.addEventListener('blur', stopHeldStep);
    return () => {
      window.removeEventListener('keydown', onKeyDown);
      window.removeEventListener('keyup', onKeyUp);
      window.removeEventListener('blur', stopHeldStep);
      stopHeldStep();
    };
  }, [isViewingSimulation, playbackMaxPosition, playbackTickCount, setDisplayedStepSpeed, setDisplayedTickPosition]);

  const canStepBack = isViewingSimulation && playbackTickCount > 1 && clampedTickPosition > 0;
  const canStepForward = isViewingSimulation && playbackTickCount > 1 && clampedTickPosition < playbackMaxPosition;

  const stepBack = useCallback(() => {
    if (!canStepBack) return;
    setDisplayedTickPosition(Math.max(0, Math.round(tickPositionRef.current) - 1));
  }, [canStepBack, setDisplayedTickPosition]);

  const stepForward = useCallback(() => {
    if (!canStepForward) return;
    setDisplayedTickPosition(Math.min(playbackMaxPosition, Math.round(tickPositionRef.current) + 1));
  }, [canStepForward, playbackMaxPosition, setDisplayedTickPosition]);

  const cell = {
    fontFamily: "'Courier New', monospace",
    background: '#C3C4CA',
    border: '1px solid rgba(0,0,0,0.13)',
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    height: 28,
    lineHeight: 1,
  };
  const panelRow = PANEL_ROW;
  const panelLabel = PANEL_LABEL;
  const panelValue = PANEL_VALUE;
  const panelWrappedValue = PANEL_WRAPPED_VALUE;
  const renderPanelRow = (label, value, options = {}) => (
    <div style={panelRow}>
      <span style={panelLabel}>{label}</span>
      <span style={{ ...panelValue, ...(options.wrap ? panelWrappedValue : null) }}>{value ?? '—'}</span>
    </div>
  );
  const missionSummary = selectedMission?.name ?? 'Pick a mission brief';
  const briefSummary = missionBrief
    ? `${missionBrief.name} · ${(missionBrief.primary_stressor ?? 'conditions').replaceAll('_', ' ')}`
    : 'Select a mission for conditions';
  const campaignSummary = selectedCampaign
    ? `${selectedCampaign.id} · ${selectedCampaignStatus} · ${selectedCampaign.count} runs`
    : (visibleCampaigns.length ? `${visibleCampaigns.length} campaigns` : 'No campaigns yet');
  const runsSummary = visibleSimulations.length
    ? `${visibleSimulations.length} runs · ${selectedSimulation ? displayStatus(selectedSimulation.status) : 'none selected'}`
    : 'No saved simulations';
  const analysisSummary = selectedSimulation
    ? `${displayStatus(selectedSimulation.status)}${Number.isFinite(selectedSimulation?.eval?.score_pct) ? ` · ${selectedSimulation.eval.score_pct}%` : ''}`
    : (simResult?.failure ? failureDetail : 'Load a run for analysis');
  const paramsSummary = config
    ? `${fmtNumber(config.shell_mass_kg, 0)} kg shell · ${displayedZones.length} zones`
    : 'Run a mission to load config';
  const pointA = pickedPoints[0] ? `${pickedPoints[0].lat_deg.toFixed(2)}, ${pickedPoints[0].lon_deg.toFixed(2)}` : '—';
  const pointB = pickedPoints[1] ? `${pickedPoints[1].lat_deg.toFixed(2)}, ${pickedPoints[1].lon_deg.toFixed(2)}` : '—';

  return (
    <div style={{ width: '100vw', height: '100vh', overflow: 'hidden', background: SF_BG, position: 'relative' }}>
      <HullDiagram
        simResult={simResult}
        loading={loading}
        progress={hasStartedPointRun ? liveShipProgress : tickProgress}
        activeTick={visualTick ?? activeTick}
        routeGeo={visualRoute}
        onGlobePoint={hasStartedPointRun ? null : pickGlobePoint}
        freeCamera={!hasStartedPointRun}
        showShip={hasStartedPointRun}
      />

      <div style={{
        position: 'absolute',
        top: 18,
        left: 18,
        zIndex: 12,
        width: 430,
        maxHeight: 'calc(100vh - 36px)',
        display: 'flex',
        flexDirection: 'column',
        background: 'rgba(195,196,202,0.96)',
        border: '1px solid rgba(0,0,0,0.16)',
        fontFamily: "'Courier New', monospace",
        color: 'rgba(0,0,0,0.72)',
      }}>
        <button
          type="button"
          onClick={() => setAgentsOpen((open) => !open)}
          style={{
            width: '100%',
            padding: '12px 14px',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            gap: 12,
            background: 'transparent',
            border: 'none',
            borderBottom: agentsOpen ? '1px solid rgba(0,0,0,0.10)' : 'none',
            cursor: 'pointer',
            fontFamily: "'Courier New', monospace",
          }}
        >
          <span style={{ fontSize: 10, fontWeight: 700, letterSpacing: '0.13em', textTransform: 'uppercase' }}>
            Spawn Sub Agents
          </span>
          <span style={{ fontSize: 10, color: 'rgba(0,0,0,0.45)' }}>{agentsOpen ? '▼' : '▶'}</span>
        </button>

        {agentsOpen ? (
          <div className="no-scrollbar" style={{ overflowY: 'auto', padding: '12px 14px 14px' }}>
            <div style={{ fontSize: 11, lineHeight: 1.45, marginBottom: 8 }}>{agentStatus}</div>
            <div style={{ display: 'flex', gap: 14, fontSize: 9, color: 'rgba(0,0,0,0.48)', marginBottom: 4 }}>
              <span>A · {pointA}</span>
              <span>B · {pointB}</span>
              {hasStartedPointRun ? <span>RUNS {agentIterations}</span> : null}
            </div>
            <LearningMiniGraph
              iterations={learningIterations}
              selectedIndex={activeAttemptIndex}
              onSelect={(index) => {
                const attempt = learningIterations[index];
                setActiveAttemptIndex(index);
                setLiveShipProgress(Math.max(
                  0,
                  Math.min(1, Number(attempt?.result?.distance_pct ?? 0) / 100),
                ));
              }}
            />
            <div style={{ display: 'flex', gap: 8, marginTop: 10, marginBottom: 4 }}>
              {runningGemini && hasStartedPointRun ? (
                <div style={{
                  width: '100%',
                  minHeight: 36,
                  padding: '9px 11px',
                  boxSizing: 'border-box',
                  border: '1px solid rgba(0,0,0,0.18)',
                  background: 'rgba(0,0,0,0.055)',
                  font: "700 10px 'Courier New', monospace",
                  letterSpacing: '0.06em',
                  lineHeight: 1.5,
                  textTransform: 'uppercase',
                  color: 'rgba(0,0,0,0.68)',
                }}>
                  {agentStatus}
                </div>
              ) : (
                <>
                  <button
                    type="button"
                    disabled={pickedPoints.length !== 2}
                    onClick={() => runPointSimulation(pickedPoints[0], pickedPoints[1])}
                    style={{
                      flex: 1,
                      padding: '9px 10px',
                      border: '1px solid rgba(0,0,0,0.18)',
                      color: pickedPoints.length === 2 ? 'rgba(0,0,0,0.76)' : 'rgba(0,0,0,0.30)',
                      background: pickedPoints.length === 2 ? 'rgba(0,0,0,0.08)' : 'rgba(0,0,0,0.025)',
                      font: "700 10px 'Courier New', monospace",
                      letterSpacing: '0.08em',
                      cursor: pickedPoints.length === 2 ? 'pointer' : 'default',
                    }}
                  >
                    SPAWN SUB AGENT
                  </button>
                  {pickedPoints.length > 0 ? (
                    <button
                      type="button"
                      onClick={() => {
                        setPickedPoints([]);
                        setAgentIterations(0);
                        setLearningIterations([]);
                        setHasStartedPointRun(false);
                        setLiveShipProgress(0);
                        setActiveAttemptIndex(null);
                        setPlannedWaypoints([]);
                        setAgentStatus('Click the globe to choose point A');
                      }}
                      style={{
                        padding: '6px 10px',
                        border: '1px solid rgba(0,0,0,0.16)',
                        background: 'rgba(0,0,0,0.04)',
                        font: "700 9px 'Courier New', monospace",
                        cursor: 'pointer',
                      }}
                    >
                      RESET
                    </button>
                  ) : null}
                </>
              )}
            </div>

            <AgentSection
              title="Missions"
              summary={missionSummary}
              open={openSections.missions}
              onToggle={() => toggleSection('missions')}
            >
              {MISSIONS.map((m) => {
                const isSelected = selectedMission?.id === m.id;
                return (
                  <div
                    key={m.id}
                    onClick={() => {
                      setSelectedSimulationId(null);
                      setSelectedMission(isSelected ? null : m);
                      if (!isSelected) {
                        setOpenSections((current) => ({ ...current, brief: true }));
                      }
                    }}
                    style={{
                      padding: '7px 0',
                      fontSize: 10,
                      letterSpacing: '0.02em',
                      whiteSpace: 'nowrap',
                      cursor: 'pointer',
                      color: isSelected ? 'rgba(0,0,0,0.82)' : 'rgba(0,0,0,0.55)',
                      background: isSelected ? 'rgba(0,0,0,0.05)' : 'transparent',
                      borderBottom: '1px solid rgba(0,0,0,0.06)',
                      display: 'flex',
                      alignItems: 'baseline',
                      gap: 8,
                    }}
                  >
                    <span style={{ color: 'rgba(0,0,0,0.25)', fontSize: 9 }}>{m.id.split('_')[0]}</span>
                    {m.name}
                  </div>
                );
              })}
            </AgentSection>

            <AgentSection
              title="Mission Brief"
              summary={briefSummary}
              open={openSections.brief}
              onToggle={() => toggleSection('brief')}
            >
              {missionBrief ? (
                <>
                  {renderPanelRow('Mission', missionBrief.name, { wrap: true })}
                  {missionBrief?.objective ? renderPanelRow('Objective', missionBrief.objective, { wrap: true }) : null}
                  {renderPanelRow('Physics', missionBrief.primary_stressor?.replaceAll('_', ' '), { wrap: true })}
                  {renderPanelRow('Failure', (missionBrief.failure_modes_under_test ?? []).join(', ') || '—', { wrap: true })}
                  {renderPanelRow('Waves', fmtRange(env?.wave_height_m, 'm'))}
                  {renderPanelRow('Wind', missionFactor('—'))}
                  {renderPanelRow('Slamming', missionFactor(env?.slamming_probability ?? '—'))}
                  {renderPanelRow('Water', missionFactor(fmtRange(env?.water_temp_c, '°C')))}
                  {renderPanelRow('Ice', missionFactor(env?.ice_accretion_risk ?? '—'))}
                  {renderPanelRow('Salinity', missionFactor(`${fmtNumber(env?.salinity_ppt)} ppt`))}
                  {renderPanelRow('pH', missionFactor(fmtNumber(env?.ph, 2)))}
                </>
              ) : (
                <div style={{ ...panelRow, display: 'block', color: 'rgba(0,0,0,0.42)' }}>
                  Select a mission to load brief and sea conditions.
                </div>
              )}
            </AgentSection>

            <AgentSection
              title="Campaigns"
              summary={campaignSummary}
              open={openSections.campaigns}
              onToggle={() => toggleSection('campaigns')}
            >
              <div className="no-scrollbar" style={{ maxHeight: 120, overflowY: 'auto', marginBottom: 8 }}>
                {visibleCampaigns.length === 0 ? (
                  <div style={{ fontSize: 10, color: 'rgba(0,0,0,0.42)' }}>No campaigns yet. Run agent on a mission.</div>
                ) : visibleCampaigns.map((campaign) => {
                  const isSelected = selectedCampaignId === campaign.id;
                  return (
                    <div
                      key={campaign.id}
                      onClick={() => selectCampaign(campaign.id)}
                      style={{
                        padding: '7px 0',
                        fontSize: 10,
                        cursor: 'pointer',
                        color: isSelected ? 'rgba(0,0,0,0.82)' : 'rgba(0,0,0,0.55)',
                        background: isSelected ? 'rgba(0,0,0,0.05)' : 'transparent',
                        borderBottom: '1px solid rgba(0,0,0,0.06)',
                        display: 'grid',
                        gridTemplateColumns: '1fr auto',
                        gap: 10,
                      }}
                    >
                      <span style={{ overflow: 'hidden', textOverflow: 'ellipsis' }}>{campaign.id}</span>
                      <span style={{ fontWeight: 700 }}>{campaign.count}</span>
                    </div>
                  );
                })}
              </div>
              {selectedCampaign ? (
                <>
                  {renderPanelRow('Status', selectedCampaignStatus)}
                  {renderPanelRow('Mission', campaignMission?.name ?? '—', { wrap: true })}
                  {renderPanelRow('Runs', String(selectedCampaign.count))}
                  {renderPanelRow('Success', String(campaignSuccessCount))}
                  {renderPanelRow('Failed', String(campaignFailureCount))}
                  {bestSimulationLabel ? renderPanelRow('Best', bestSimulationLabel, { wrap: true }) : null}
                  {latestCampaignSimulation ? renderPanelRow('Latest', `${String(latestCampaignSimulation.iteration).padStart(2, '0')} ${displayStatus(latestCampaignSimulation.status)}`, { wrap: true }) : null}
                  {renderPanelRow('Leg', activeRouteSegment?.label ?? '—', { wrap: true })}
                </>
              ) : (
                <div style={{ ...panelRow, display: 'block', color: 'rgba(0,0,0,0.42)' }}>
                  Select a campaign for details.
                </div>
              )}
            </AgentSection>

            <AgentSection
              title="Simulation Runs"
              summary={runsSummary}
              open={openSections.runs}
              onToggle={() => toggleSection('runs')}
            >
              <div className="no-scrollbar" style={{ maxHeight: 150, overflowY: 'auto' }}>
                {visibleSimulations.length === 0 ? (
                  <div style={{ fontSize: 10, color: 'rgba(0,0,0,0.42)' }}>No saved simulations.</div>
                ) : visibleSimulations.map((sim) => {
                  const isSelected = selectedSimulationId === sim.id;
                  const failure = sim.failure?.mode ?? displayStatus(sim.status);
                  const evalScore = Number.isFinite(sim.eval?.score_pct) ? `${sim.eval.score_pct}%` : '—';
                  return (
                    <div
                      key={sim.id}
                      onClick={() => {
                        loadSavedSimulation(sim.id);
                        setOpenSections((current) => ({ ...current, analysis: true, params: true }));
                      }}
                      style={{
                        padding: '6px 0',
                        fontSize: 10,
                        cursor: 'pointer',
                        color: isSelected ? 'rgba(0,0,0,0.82)' : 'rgba(0,0,0,0.55)',
                        background: isSelected ? 'rgba(0,0,0,0.05)' : 'transparent',
                        borderBottom: '1px solid rgba(0,0,0,0.05)',
                        display: 'grid',
                        gridTemplateColumns: '1fr auto',
                        gap: 10,
                      }}
                    >
                      <span style={{ overflow: 'hidden', textOverflow: 'ellipsis' }}>
                        <span style={{ color: 'rgba(0,0,0,0.28)' }}>{String(sim.iteration).padStart(2, '0')}</span>
                        {' '}{failure}
                      </span>
                      <span style={{ fontWeight: 700 }}>{evalScore}</span>
                    </div>
                  );
                })}
              </div>
            </AgentSection>

            <AgentSection
              title="Cost & Analysis"
              summary={analysisSummary}
              open={openSections.analysis}
              onToggle={() => toggleSection('analysis')}
            >
              {renderPanelRow('Total', simResult?.result?.total_config_cost_usd
                ? `$${simResult.result.total_config_cost_usd.toLocaleString('en-US', { maximumFractionDigits: 0 })}`
                : '—')}
              {selectedSimulation || simResult?.failure ? (
                <>
                  {selectedSimulation ? renderPanelRow('Status', displayStatus(selectedSimulation.status)) : null}
                  {Number.isFinite(selectedSimulation?.eval?.score_pct) ? renderPanelRow('Eval', `${selectedSimulation.eval.score_pct}%`) : null}
                  {selectedSimulation?.assessment?.model_used ? renderPanelRow('Model', selectedSimulation.assessment.model_used, { wrap: true }) : null}
                  {selectedSimulation?.assessment?.assessment ? renderPanelRow('Thoughts', selectedSimulation.assessment.assessment, { wrap: true }) : null}
                  {selectedSimulation?.assessment?.failed_part ? renderPanelRow('Part', selectedSimulation.assessment.failed_part, { wrap: true }) : null}
                  {selectedSimulation?.assessment?.failed_metric ? renderPanelRow('Metric', selectedSimulation.assessment.failed_metric, { wrap: true }) : null}
                  {selectedSimulation?.assessment?.root_cause ? renderPanelRow('Cause', selectedSimulation.assessment.root_cause, { wrap: true }) : null}
                  {selectedSimulation?.assessment?.changes?.length
                    ? renderPanelRow('Solution', selectedSimulation.assessment.changes.join('; '), { wrap: true })
                    : null}
                  {simResult?.failure ? renderPanelRow('Failed', failureDetail, { wrap: true }) : null}
                </>
              ) : (
                <div style={{ ...panelRow, display: 'block', color: 'rgba(0,0,0,0.42)' }}>
                  Load a simulation to view analysis.
                </div>
              )}
            </AgentSection>

            <AgentSection
              title="Parameters"
              summary={paramsSummary}
              open={openSections.params}
              onToggle={() => toggleSection('params')}
            >
              {config ? (
                <>
                  {renderPanelRow('Shell mass', `${fmtNumber(config.shell_mass_kg, 0)} kg`)}
                  {config.propulsion ? renderPanelRow('Fuel cap', `${fmtNumber(config.propulsion.fuel_capacity_kg, 0)} kg`) : null}
                  {config.propulsion ? renderPanelRow('Efficiency', fmtNumber(config.propulsion.propulsive_efficiency, 2)) : null}
                  {config.propulsion ? renderPanelRow('Drag coeff', fmtNumber(config.propulsion.hull_drag_coeff, 4)) : null}
                  {displayedZones.map((zone, index) => (
                    <div
                      key={`${zone.zone_key ?? zone.zone}-${index}`}
                      style={{
                        padding: '6px 0 7px',
                        fontSize: 10,
                        lineHeight: 1.25,
                        color: 'rgba(0,0,0,0.70)',
                        borderTop: index ? '1px solid rgba(0,0,0,0.06)' : 'none',
                      }}
                    >
                      <div style={{ color: 'rgba(0,0,0,0.74)', marginBottom: 3 }}>{zone.zone ?? 'Component'}</div>
                      <div style={{ display: 'grid', gridTemplateColumns: '70px 1fr', gap: 6, color: 'rgba(0,0,0,0.48)' }}>
                        <span>MAT</span><span style={panelValue}>{zone.material_label ?? zone.material ?? '—'}</span>
                        <span>THK</span><span style={panelValue}>{fmtNumber(zone.thickness_mm)} mm</span>
                        <span>WLD</span><span style={panelValue}>{zone.weld_label ?? zone.weld_quality ?? '—'}</span>
                        <span>SEL</span><span style={panelValue}>{zone.seal_label ?? zone.seal_quality ?? '—'}</span>
                      </div>
                    </div>
                  ))}
                </>
              ) : (
                <div style={{ ...panelRow, display: 'block', color: 'rgba(0,0,0,0.42)' }}>
                  Run a mission to load configuration.
                </div>
              )}
            </AgentSection>

            <div style={{ display: 'flex', gap: 0, marginTop: 12 }}>
              <button
                type="button"
                onClick={runGeminiSimulations}
                disabled={runningGemini || !selectedMission}
                style={{
                  width: runningGemini && !hasStartedPointRun ? '63%' : '100%',
                  height: 40,
                  fontFamily: "'Courier New', monospace",
                  fontSize: 11,
                  fontWeight: 700,
                  letterSpacing: '0.08em',
                  textTransform: 'uppercase',
                  cursor: runningGemini || !selectedMission ? 'default' : 'pointer',
                  color: runningGemini || !selectedMission ? 'rgba(0,0,0,0.34)' : 'rgba(0,0,0,0.76)',
                  background: runningGemini || !selectedMission ? 'rgba(0,0,0,0.035)' : 'rgba(0,0,0,0.075)',
                  border: '1px solid rgba(0,0,0,0.16)',
                }}
              >
                {runningGemini && !hasStartedPointRun ? (
                  <>
                    Running Agent
                    <span style={{ display: 'inline-block', width: '3ch', textAlign: 'left' }}>
                      {'.'.repeat(geminiDotCount)}
                    </span>
                  </>
                ) : 'Run Mission Agent'}
              </button>
              {runningGemini && !hasStartedPointRun ? (
                <button
                  type="button"
                  onClick={stopGeminiSimulations}
                  style={{
                    width: '37%',
                    height: 40,
                    marginLeft: -1,
                    fontFamily: "'Courier New', monospace",
                    fontSize: 11,
                    fontWeight: 700,
                    letterSpacing: '0.08em',
                    textTransform: 'uppercase',
                    cursor: 'pointer',
                    color: 'rgba(120,0,0,0.82)',
                    background: 'rgba(180,0,0,0.08)',
                    border: '1px solid rgba(120,0,0,0.24)',
                  }}
                >
                  Stop
                </button>
              ) : null}
            </div>
          </div>
        ) : (
          <div style={{ padding: '0 14px 12px', fontSize: 9, color: 'rgba(0,0,0,0.45)' }}>
            A · {pointA} · B · {pointB}{selectedMission ? ` · ${selectedMission.name}` : ''}
          </div>
        )}
      </div>


      {/* Floating transport controls */}
      <div style={{
        position: 'absolute',
        bottom: 24,
        left: '50%',
        transform: 'translateX(-50%)',
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'center',
        userSelect: 'none',
      }}>
        <div style={{
          ...cell,
          width: 108,
          height: 28,
          marginBottom: -1,
          fontSize: 10,
          fontWeight: 700,
          letterSpacing: '0.06em',
          textTransform: 'uppercase',
          color: 'rgba(0,0,0,0.38)',
        }}>
          {activeDayLabel}
        </div>

      </div>
    </div>
  );
}
