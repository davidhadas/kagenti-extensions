import type { Agent, TokenBrokerEvent } from '@/types';

const API_BASE = '/api/v1';

let tokenGetter: (() => Promise<string | null>) | null = null;

export function setTokenGetter(getter: () => Promise<string | null>): void {
  tokenGetter = getter;
}

async function authHeaders(): Promise<Record<string, string>> {
  if (!tokenGetter) return {};
  const token = await tokenGetter();
  return token ? { Authorization: `Bearer ${token}` } : {};
}

async function apiGet<T>(endpoint: string): Promise<T> {
  const response = await fetch(`${API_BASE}${endpoint}`, {
    headers: { 'Content-Type': 'application/json', ...(await authHeaders()) },
  });
  if (!response.ok) {
    const err = await response.json().catch(() => ({}));
    throw new Error(err.detail || `API error: ${response.status} ${response.statusText}`);
  }
  return response.json();
}

export const namespaceService = {
  async list(): Promise<string[]> {
    const r = await apiGet<{ namespaces: string[] }>('/namespaces?enabled_only=true');
    return r.namespaces;
  },
};

export const agentService = {
  async list(namespace: string): Promise<Agent[]> {
    const r = await apiGet<{ items: Agent[] }>(`/agents?namespace=${encodeURIComponent(namespace)}`);
    return r.items;
  },
};

export const tokenBrokerService = {
  /** Create (or reuse) the token-broker session. Returns true on 201. */
  async createSession(redirectUrl: string): Promise<boolean> {
    try {
      const response = await fetch(`${API_BASE}/token-broker/session`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', ...(await authHeaders()) },
        body: JSON.stringify({ redirect_url: redirectUrl }),
      });
      return response.status === 201;
    } catch {
      return false;
    }
  },

  /** Long-poll for the next broker event. Throws "Poll failed: <status>" on
   *  error (the caller inspects 401/404 to self-heal the session). */
  async pollEvents(): Promise<TokenBrokerEvent | null> {
    const response = await fetch(`${API_BASE}/token-broker/ui-events`, {
      headers: await authHeaders(),
    });
    if (response.status === 204) return null;
    if (!response.ok) throw new Error(`Poll failed: ${response.status}`);
    return response.json();
  },

  async endSession(): Promise<void> {
    await fetch(`${API_BASE}/token-broker/session`, {
      method: 'DELETE',
      headers: await authHeaders(),
    }).catch(() => {});
  },
};
