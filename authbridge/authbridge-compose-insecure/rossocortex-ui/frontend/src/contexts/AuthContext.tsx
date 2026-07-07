/**
 * RossoCortex AuthContext — simulated IdP flow.
 *
 * Single session ownership rule:
 *   Only AuthContext creates or recreates the token-broker session.
 *   ChatPage never calls createSession() — it only calls renewSession()
 *   when it detects the session is gone (404 on ui-events).
 *
 * sessionReadyRef is a ref (not state) so the polling loop can read it
 * synchronously with no React render cycle and no race condition:
 *   - renewSession() sets sessionReadyRef.current = false synchronously
 *   - polling loop reads it on every iteration and pauses immediately
 *   - after session is recreated: sessionReadyRef.current = true
 *   - polling loop resumes on next iteration
 */
import React, {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
} from 'react';

import { setTokenGetter, tokenBrokerService } from '@/services/api';
import type { AuthConfig, User } from '@/types';

const API_BASE = '/api/v1';
const TOKEN_KEY = 'rossocortex_access_token';

interface AuthContextType {
  isAuthenticated: boolean;
  isLoading: boolean;
  isEnabled: boolean;
  tokenBrokerEnabled: boolean;
  user: User | null;
  login: () => void;
  logout: () => void;
  getToken: () => Promise<string | null>;
  // ref — synchronously readable from polling loops, no render cycle
  sessionReadyRef: React.MutableRefObject<boolean>;
  // single entry point for session creation / recreation
  renewSession: () => Promise<boolean>;
  // App-wide token-broker connectivity — drives the masthead indicator and
  // Send gating. Updated by the event loop.
  sessionHealthy: boolean;
  setSessionHealthy: (healthy: boolean) => void;
  // false during startup (or right after an OAuth redirect reload) until the
  // health picture has settled — i.e. the event loop has resolved the first
  // poll. Consumers must ignore sessionHealthy while !loaded (don't abort
  // resumed tasks on the transient initial false).
  loaded: boolean;
}

const AuthContext = createContext<AuthContextType | undefined>(undefined);

function parseJwtPayload(token: string): Record<string, unknown> {
  try {
    const payload = token.split('.')[1];
    return JSON.parse(atob(payload.replace(/-/g, '+').replace(/_/g, '/')));
  } catch {
    return {};
  }
}

function userFromToken(token: string): User {
  const claims = parseJwtPayload(token);
  return {
    username: (claims.preferred_username as string) || (claims.sub as string) || 'demo-user',
  };
}

export const AuthProvider: React.FC<{ children: React.ReactNode }> = ({ children }) => {
  const [isAuthenticated, setIsAuthenticated] = useState(false);
  const [isLoading, setIsLoading]             = useState(true);
  const [isEnabled, setIsEnabled]             = useState(false);
  const [tokenBrokerEnabled, setTokenBrokerEnabled] = useState(false);
  const [user, setUser]                       = useState<User | null>(null);
  const [sessionHealthy, setSessionHealthy]   = useState(false);
  const [loaded, setLoaded]                   = useState(false);
  const tokenRef                              = useRef<string | null>(null);

  // sessionReadyRef: true = session exists and polling may proceed.
  // Written synchronously so polling loops read the correct value
  // without waiting for a React re-render.
  const sessionReadyRef = useRef<boolean>(false);

  const getToken = useCallback(async (): Promise<string | null> => {
    return tokenRef.current ?? sessionStorage.getItem(TOKEN_KEY);
  }, []);

  // renewSession: the single path for creating or recreating a session.
  // Sets sessionReadyRef.current = false synchronously before doing anything,
  // then creates the session, then sets it back to true.
  const renewSession = useCallback(async (): Promise<boolean> => {
    sessionReadyRef.current = false;
    // Full-page redirect model: after OAuth the token-broker redirects the
    // whole browser here. /oauth-resume reads the pending task from
    // sessionStorage and navigates back to the correct chat page.
    const redirectUrl = window.location.origin + '/oauth-resume';
    const ok = await tokenBrokerService.createSession(redirectUrl);
    if (ok) {
      sessionReadyRef.current = true;
      console.log('[AuthContext] Session ready');
    } else {
      console.warn('[AuthContext] Session creation failed');
    }
    return ok;
  }, []);

  const login = useCallback(() => {
    const redirectUri = window.location.origin + '/auth/callback';
    fetch(`${API_BASE}/auth/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ redirect_uri: redirectUri }),
    })
      .then(r => r.json())
      .then(({ url }) => { window.location.href = url; })
      .catch(console.error);
  }, []);

  const logout = useCallback(async () => {
    sessionReadyRef.current = false;
    await tokenBrokerService.endSession();
    sessionStorage.removeItem(TOKEN_KEY);
    tokenRef.current = null;
    setIsAuthenticated(false);
    setUser(null);
    // Navigate to / WITHOUT a full-page reload so AuthProvider stays mounted
    // and init() does NOT re-run (which would immediately auto-login again).
    // The landing page shows a manual Sign In button instead.
    window.history.replaceState(null, '', '/');
    // Dispatch a popstate so React Router picks up the URL change.
    window.dispatchEvent(new PopStateEvent('popstate'));
  }, []);

  useEffect(() => {
    let cancelled = false;

    async function init() {
      // On the OAuth callback route, CallbackPage exclusively handles the code
      // exchange and token storage. init() must NOT run here — otherwise it
      // sees no token yet and fires a SECOND login, minting a competing token
      // that overwrites the callback's and breaks session/jti consistency.
      if (window.location.pathname.startsWith('/auth/callback')) {
        setIsLoading(false);
        return;
      }
      try {
        const resp = await fetch(`${API_BASE}/auth/config`);
        const config: AuthConfig = await resp.json();

        const brokerEnabled = config.token_broker_enabled ?? false;
        if (!cancelled) setTokenBrokerEnabled(brokerEnabled);
        // No broker → no health to resolve → loaded immediately (chat works
        // without HITL, no gating). With a broker, the event loop sets loaded
        // once the first poll resolves the health picture.
        if (!brokerEnabled && !cancelled) setLoaded(true);

        if (!config.enabled) {
          if (!cancelled) setIsEnabled(false);
          return;
        }
        if (!cancelled) setIsEnabled(true);

        const stored = sessionStorage.getItem(TOKEN_KEY);
        if (stored) {
          tokenRef.current = stored;
          if (!cancelled) {
            setIsAuthenticated(true);
            setUser(userFromToken(stored));
            setTokenGetter(() => getToken());
          }
          // Create session once after auth — same as original does after kc.init().
          if (config.token_broker_enabled && !cancelled) {
            await renewSession();
          }
          return;
        }

        // No token — show landing page for manual sign-in (no auto-login).
        if (!cancelled) setIsLoading(false);
      } catch (err) {
        console.error('[AuthContext] init failed:', err);
      } finally {
        if (!cancelled) setIsLoading(false);
      }
    }

    init();
    return () => { cancelled = true; };
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  // ── App-wide token-broker event loop ─────────────────────────────────────────
  // Runs on every page (lives in the provider, not a page component) so the
  // masthead connectivity indicator reflects the LIVE /ui-events connection:
  //   - a returning poll → sessionHealthy = true  (green)
  //   - a failing poll / broker error → sessionHealthy = false (orange), self-heal
  //   - session_ended sentinel → reconnect to the new session
  //   - oauth_url_ready → full-page redirect to the auth URL
  useEffect(() => {
    if (!tokenBrokerEnabled) return;
    let running = true;

    const t = () => new Date().toISOString().substr(11, 12);  // HH:MM:SS.mmm
    const loop = async () => {
      console.log(`[RC-auth ${t()}] event loop STARTED`);
      while (running) {
        if (!sessionReadyRef.current) {
          setSessionHealthy(false);
          await new Promise((r) => setTimeout(r, 100));
          continue;
        }
        try {
          // A session exists and we're about to hold an open long-poll —
          // that IS a live connection. Mark healthy NOW (green immediately),
          // not only when the poll eventually returns. Health is now resolved.
          setSessionHealthy(true);
          setLoaded(true);
          console.log(`[RC-auth ${t()}] poll → GET /ui-events (healthy → green)`);
          const started = performance.now();
          const event = await tokenBrokerService.pollEvents();
          const dt = Math.round(performance.now() - started);
          if (!running) break;
          const type = event?.type ?? 'null';
          console.log(`[RC-auth ${t()}] poll ← ${type} (${dt}ms)`);

          if (event && event.type === 'session_ended') {
            console.log(`[RC-auth ${t()}] session_ended → reconnect`);
            continue;
          }
          if (event && event.type === 'error') {
            console.error(`[RC-auth ${t()}] BROKER ERROR → orange. msg=`, event.message);
            setSessionHealthy(false);
            setLoaded(true);
            await new Promise((r) => setTimeout(r, 2000));
            continue;
          }
          // Poll returned cleanly (event / null) — still connected.
          if (event && event.type === 'oauth_url_ready' && event.auth_url) {
            console.log(`[RC-auth ${t()}] oauth_url_ready → full-page redirect`);
            window.location.href = event.auth_url;
            return;
          }
        } catch (error: any) {
          if (!running) break;
          const msg = String(error) + ' | ' + (error?.message || '');
          console.error(`[RC-auth ${t()}] poll THREW → orange. err=`, msg);
          setSessionHealthy(false);
          setLoaded(true);
          if (msg.includes('401') || msg.includes('404')) {
            console.warn(`[RC-auth ${t()}] session failure → renewSession`);
            await renewSession();
          } else {
            console.warn(`[RC-auth ${t()}] non-session error → retry in 2s`);
            await new Promise((r) => setTimeout(r, 2000));
          }
        }
      }
      console.log(`[RC-auth ${t()}] event loop STOPPED`);
    };
    loop();
    return () => { running = false; };
  }, [tokenBrokerEnabled, renewSession]);

  const value = useMemo(() => ({
    isAuthenticated,
    isLoading,
    isEnabled,
    tokenBrokerEnabled,
    user,
    login,
    logout,
    getToken,
    sessionReadyRef,
    renewSession,
    sessionHealthy,
    setSessionHealthy,
    loaded,
  }), [isAuthenticated, isLoading, isEnabled, tokenBrokerEnabled, user, login, logout, getToken, renewSession, sessionHealthy, loaded]);

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
};

export function useAuth(): AuthContextType {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error('useAuth must be used within an AuthProvider');
  return ctx;
}
