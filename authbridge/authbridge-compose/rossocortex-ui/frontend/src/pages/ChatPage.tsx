/**
 * ChatPage — async task + full-page-redirect OAuth model.
 *
 * Send flow:
 *   1. POST /chat/{ns}/{name}/send → returns {task_id} immediately (202).
 *      The BFF runs the blocking agent call in the background.
 *   2. Save {taskId, namespace, name, sessionId, responses} to sessionStorage.
 *   3. Poll GET /chat/result/{task_id} until done/error.
 *
 * OAuth flow (no popup, no tab):
 *   - The event loop long-polls /token-broker/ui-events.
 *   - On oauth_url_ready → FULL-PAGE redirect: window.location.href = auth_url.
 *   - The browser leaves the SPA, but the agent request keeps running in the BFF.
 *   - After OAuth the token-broker redirects the browser to /oauth-resume,
 *     which navigates back here. On mount we detect the pending task in
 *     sessionStorage, restore the chat, and resume polling for its result.
 */
import React, { useState, useEffect, useRef, useCallback } from 'react';
import {
  Button, Card, CardBody, Label, TextArea, Title, Text, TextContent,
  Spinner, Alert, Flex, FlexItem, Divider,
} from '@patternfly/react-core';
import { ArrowLeftIcon, PaperPlaneIcon } from '@patternfly/react-icons';
import { useNavigate, useParams, useLocation } from 'react-router-dom';

import type { Agent } from '@/types';

import { useAuth } from '@/contexts/AuthContext';

const API_BASE = '/api/v1';
const PENDING_KEY = 'rossocortex_pending_task';

type Msg = { role: 'user' | 'agent'; text: string };

interface PendingTask {
  taskId: string;
  namespace: string;
  name: string;
  sessionId?: string;
  responses: Msg[];
}

async function getToken(): Promise<string | null> {
  return sessionStorage.getItem('rossocortex_access_token');
}

export const ChatPage: React.FC = () => {
  const { namespace, name } = useParams<{ namespace: string; name: string }>();
  const navigate = useNavigate();
  const location = useLocation();
  const agent = (location.state as { agent?: Agent } | null)?.agent ?? null;
  const {
    tokenBrokerEnabled, renewSession,
    sessionHealthy, setSessionHealthy, loaded,
  } = useAuth();

  const [message, setMessage] = useState('');
  const [sessionId, setSessionId] = useState<string | undefined>();
  const [responses, setResponses] = useState<Msg[]>([]);
  const [waiting, setWaiting] = useState(false);
  const [oauthStatus, setOauthStatus] = useState<string | null>(null);
  // When there is no token-broker, there is no auth to gate on — Send always
  // works. "canSend" is health only when the broker is in play.
  const canSend = !tokenBrokerEnabled || sessionHealthy;

  const resultPollRef = useRef(false);   // result poll guard
  // Abort reason for an in-flight task. null = no abort. 'broker' = the broker
  // failed mid-task; 'user' = the user pressed New session.
  const abortResultRef = useRef<null | 'broker' | 'user'>(null);
  // AbortController for the in-flight /chat/result long-poll, so an abort can
  // interrupt the blocked fetch immediately (it's server-blocked otherwise).
  const resultAbortRef = useRef<AbortController | null>(null);

  // Signal a mid-task abort: record the reason and interrupt the blocked
  // /chat/result long-poll so pollResult's catch handles it right away.
  const abortInFlightTask = (reason: 'broker' | 'user') => {
    if (resultPollRef.current && !abortResultRef.current) {
      abortResultRef.current = reason;
      resultAbortRef.current?.abort();
    }
  };

  // ── Long-poll the BFF for a task's result ────────────────────────────────────
  // GET /chat/result blocks server-side until the result is ready; no interval.
  // A mid-task abort (broker failure / New session) aborts the fetch via the
  // AbortController, then cancels the agent task on the BFF.
  const pollResult = useCallback(async (taskId: string) => {
    if (resultPollRef.current) {
      console.log('[RC] pollResult skipped — already polling');
      return;
    }
    resultPollRef.current = true;
    abortResultRef.current = null;
    const controller = new AbortController();
    resultAbortRef.current = controller;
    setWaiting(true);
    console.log('[RC] pollResult START (long-poll) task=%s', taskId);
    try {
      while (true) {
        let data: any;
        try {
          const token = await getToken();
          const res = await fetch(`${API_BASE}/chat/result/${taskId}`, {
            headers: token ? { Authorization: `Bearer ${token}` } : {},
            signal: controller.signal,
          });
          if (res.status === 404) {
            // 404 means the task is no longer in the BFF's store. The common
            // cause is NOT a restart — it's that this task was already delivered
            // and consumed by another poll (the BFF pops a task on delivery, and
            // the on-mount resume effect / a StrictMode remount can issue a
            // second poll for the same id). Treat it as a benign no-op: the
            // result, if any, was already rendered by the winning poll. Only a
            // true BFF restart also produces 404, but there's nothing to recover
            // then either, so stay quiet rather than show a misleading error.
            console.warn('[RC] pollResult 404 — task already delivered or gone; stopping quietly task=%s', taskId);
            break;
          }
          if (res.status === 401) {
            console.warn('[RC] pollResult 401 — renewing session and retrying');
            await renewSession();
            continue;
          }
          data = await res.json();
        } catch (e: any) {
          // Fetch aborted by a mid-task abort (broker failure / New session).
          if (abortResultRef.current) {
            const reason = abortResultRef.current;
            console.warn('[RC] pollResult ABORT task=%s reason=%s → cancel agent task', taskId, reason);
            fetch(`${API_BASE}/chat/cancel/${taskId}`, { method: 'POST' }).catch(() => {});
            const text = reason === 'user'
              ? 'Request cancelled — the session was reset.'
              : 'Authorization service became unavailable — the request was cancelled. Please try again when it reconnects.';
            setResponses((prev) => [...prev, { role: 'agent', text }]);
            break;
          }
          // Genuine network error (not an abort) — brief pause, reconnect.
          console.warn('[RC] pollResult fetch error, reconnecting:', e?.message || e);
          await new Promise((r) => setTimeout(r, 1500));
          continue;
        }

        if (data.status === 'done') {
          console.log('[RC] pollResult DONE task=%s (%d chars)', taskId, (data.content || '').length);
          if (data.session_id) setSessionId(data.session_id);
          setResponses((prev) => [...prev, { role: 'agent', text: data.content }]);
        } else if (data.status === 'error') {
          console.error('[RC] pollResult ERROR task=%s: %s', taskId, data.detail);
          setResponses((prev) => [...prev, { role: 'agent', text: `Error: ${data.detail || 'unknown'}` }]);
        }
        break;
      }
    } finally {
      resultPollRef.current = false;
      resultAbortRef.current = null;
      setWaiting(false);
      sessionStorage.removeItem(PENDING_KEY);
      console.log('[RC] pollResult END task=%s', taskId);
    }
  }, [renewSession]);

  // ── On mount: resume a pending task if we came back from OAuth ───────────────
  useEffect(() => {
    const raw = sessionStorage.getItem(PENDING_KEY);
    if (!raw) return;
    try {
      const p: PendingTask = JSON.parse(raw);
      if (p.namespace === namespace && p.name === name && p.taskId) {
        console.log('[RC] resume: found pending task=%s for %s/%s — restoring chat', p.taskId, namespace, name);
        setResponses(p.responses || []);
        setSessionId(p.sessionId);
        pollResult(p.taskId);
      } else {
        console.log('[RC] resume: pending task is for a different agent — ignoring');
      }
    } catch {
      sessionStorage.removeItem(PENDING_KEY);
    }
  }, [namespace, name, pollResult]);

  // Abort an in-flight task only when the broker is confirmed unhealthy AFTER
  // loading has settled. While !loaded (startup / right after the OAuth
  // redirect reload) the health signal isn't meaningful yet, so we never abort
  // a resumed task on a transient initial `false`.
  useEffect(() => {
    if (loaded && !sessionHealthy) abortInFlightTask('broker');
  }, [loaded, sessionHealthy]);

  // ── Send ─────────────────────────────────────────────────────────────────────
  const handleSend = useCallback(async () => {
    const text = message.trim();
    if (!text || waiting) return;

    const newResponses: Msg[] = [...responses, { role: 'user', text }];
    setResponses(newResponses);
    setMessage('');
    setOauthStatus(null);
    setWaiting(true);

    try {
      const token = await getToken();
      const authHeaders: Record<string, string> = token
        ? { Authorization: `Bearer ${token}` } : {};

      const res = await fetch(
        `${API_BASE}/chat/${encodeURIComponent(namespace!)}/${encodeURIComponent(name!)}/send`,
        {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', ...authHeaders },
          body: JSON.stringify({ message: text, session_id: sessionId }),
        },
      );
      if (!res.ok) {
        const detail = await res.json().catch(() => ({}));
        throw new Error(detail.detail || `send failed: ${res.status}`);
      }
      const { task_id } = await res.json();
      console.log('[RC] send: task created task=%s (agent %s/%s)', task_id, namespace, name);

      const pending: PendingTask = {
        taskId: task_id, namespace: namespace!, name: name!,
        sessionId, responses: newResponses,
      };
      sessionStorage.setItem(PENDING_KEY, JSON.stringify(pending));

      pollResult(task_id);
    } catch (err: any) {
      setResponses((prev) => [...prev, { role: 'agent', text: `Request failed: ${err.message}` }]);
      setWaiting(false);
    }
  }, [message, waiting, responses, namespace, name, sessionId, pollResult]);

  // User-driven session reset + escape hatch for a stuck task.
  // If a task is in flight, abort it (Option 1 cancel via the result loop),
  // then end+recreate the broker session. The only place we reset a session.
  const handleNewSession = useCallback(async () => {
    // Abort any in-flight task so the spinner stops immediately.
    abortInFlightTask('user');
    // Clear the conversation: New session is a clean slate, so drop all prior
    // tasks/responses and any partially-typed message. Do this up front so the
    // UI clears immediately, before the (async) broker reset.
    setResponses([]);
    setMessage('');
    setSessionId(undefined);
    setOauthStatus('Resetting authorization session…');
    setSessionHealthy(false);
    try {
      const token = await getToken();
      const authHeader: Record<string, string> = token ? { Authorization: `Bearer ${token}` } : {};

      // End the old session FIRST, then create the new one. The backend's
      // DELETE /session runs the full _cleanup(): it cancels the old poll loop
      // and pushes the session_ended sentinel into the old queue, which returns
      // (and thereby closes) the old /ui-events long-poll. Only once the old
      // session — and its /ui-events — is torn down do we create the new one,
      // so there is never more than one reader on a queue. (new-session also
      // cleans up server-side, but issuing the end explicitly from the client
      // makes the end→create ordering the frontend's contract, not an
      // implementation detail of one endpoint.)
      await fetch(`${API_BASE}/token-broker/session`, {
        method: 'DELETE',
        headers: authHeader,
      }).catch(() => {});

      const res = await fetch(`${API_BASE}/token-broker/new-session`, {
        method: 'POST',
        headers: authHeader,
      });
      if (res.status === 201) {
        setSessionHealthy(true);
        setOauthStatus(null);
        console.log('[RC] new-session: reset OK');
      } else {
        setOauthStatus('Could not reset the authorization session.');
      }
    } catch (e) {
      console.warn('[RC] new-session failed:', e);
      setOauthStatus('Could not reset the authorization session.');
    }
  }, []);

  return (
    <div style={{ maxWidth: '800px', margin: '0 auto' }}>
      <Flex alignItems={{ default: 'alignItemsCenter' }} style={{ marginBottom: '16px' }}>
        <FlexItem>
          <Button variant="link" icon={<ArrowLeftIcon />} onClick={() => navigate('/agents')}>
            Back to Agents
          </Button>
        </FlexItem>
        <FlexItem align={{ default: 'alignRight' }}>
          {/* Always enabled — it is the escape hatch for a stuck task. */}
          <Button variant="link" onClick={handleNewSession}>
            New session
          </Button>
        </FlexItem>
      </Flex>

      <div style={{ marginBottom: '24px' }}>
        <Title headingLevel="h1" size="2xl">{name}</Title>
        {agent?.description && (
          <TextContent>
            <Text component="small" style={{ color: '#6a6e73' }}>
              {agent.description}
            </Text>
          </TextContent>
        )}
      </div>

      <Divider style={{ marginBottom: '24px' }} />

      {responses.length > 0 && (
        <div style={{ marginBottom: '24px' }}>
          {responses.map((r, i) => (
            <div key={i} style={{
              marginBottom: '12px', display: 'flex',
              justifyContent: r.role === 'user' ? 'flex-end' : 'flex-start',
            }}>
              <Card style={{
                maxWidth: '80%',
                background: r.role === 'user' ? '#8b0000' : 'var(--pf-v5-global--BackgroundColor--200, #f0f0f0)',
                color: r.role === 'user' ? '#fff' : 'inherit',
              }}>
                <CardBody>
                  <TextContent>
                    <Text component="small" style={{
                      fontWeight: 600, marginBottom: '4px',
                      color: r.role === 'user' ? 'rgba(255,255,255,0.8)' : '#6a6e73',
                    }}>
                      {r.role === 'user' ? 'You' : name}
                    </Text>
                    <Text style={{ whiteSpace: 'pre-wrap', color: r.role === 'user' ? '#fff' : 'inherit' }}>
                      {r.text}
                    </Text>
                  </TextContent>
                </CardBody>
              </Card>
            </div>
          ))}
        </div>
      )}

      {waiting && (
        <div style={{ display: 'flex', alignItems: 'center', gap: '10px', marginBottom: '16px', color: '#6a6e73' }}>
          <Spinner size="md" />
          <Text>Working… (you may be asked to authorize access)</Text>
        </div>
      )}

      {oauthStatus && (
        <Alert variant="warning" title={oauthStatus} style={{ marginBottom: '16px' }} />
      )}

      {responses.length === 0 && agent?.examples && agent.examples.length > 0 && (
        <div style={{ marginBottom: '16px' }}>
          <Text component="small" style={{ color: '#6a6e73', display: 'block', marginBottom: '8px' }}>
            Try an example:
          </Text>
          <div style={{ display: 'flex', gap: '8px', flexWrap: 'wrap' }}>
            {agent.examples.map((ex, i) => (
              <Label
                key={i}
                color="blue"
                isCompact
                onClick={() => setMessage(ex)}
                style={{ cursor: 'pointer' }}
              >
                {ex}
              </Label>
            ))}
          </div>
        </div>
      )}

      <Card>
        <CardBody>
          <TextArea
            value={message}
            onChange={(_e, value) => setMessage(value)}
            placeholder={canSend ? 'Describe your task...' : 'Waiting for the authorization service…'}
            aria-label="Task message"
            rows={4}
            isDisabled={waiting || !canSend}
            onKeyDown={(e) => {
              if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); handleSend(); }
            }}
          />
          {!canSend && !waiting && (
            <Text component="small" style={{ display: 'block', marginTop: '8px', color: '#6a6e73' }}>
              Authorization service unavailable — reconnecting. Sending is
              disabled until the connection is restored.
            </Text>
          )}
          <Flex alignItems={{ default: 'alignItemsCenter' }} style={{ marginTop: '12px' }}>
            <FlexItem flex={{ default: 'flex_1' }} />
            <FlexItem>
              <Button
                variant="primary"
                icon={waiting ? <Spinner size="sm" /> : <PaperPlaneIcon />}
                onClick={handleSend}
                isDisabled={!message.trim() || waiting || !canSend}
              >
                {waiting ? 'Working…' : 'Send'}
              </Button>
            </FlexItem>
          </Flex>
        </CardBody>
      </Card>
    </div>
  );
};
