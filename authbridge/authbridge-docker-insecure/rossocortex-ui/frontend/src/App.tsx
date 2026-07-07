import React from 'react';
import { Routes, Route } from 'react-router-dom';

import { AppLayout } from '@/components/AppLayout';
import { ProtectedRoute } from '@/components/ProtectedRoute';
import { LandingPage } from '@/pages/LandingPage';
import { AgentListPage } from '@/pages/AgentListPage';
import { ChatPage } from '@/pages/ChatPage';
import { CallbackPage } from '@/pages/CallbackPage';
import { OAuthResumePage } from '@/pages/OAuthResumePage';

export const App: React.FC = () => {
  return (
    <Routes>
      {/* Callback route outside AppLayout — renders during the auth redirect */}
      <Route path="auth/callback" element={<CallbackPage />} />
      {/* OAuth resume — token-broker redirects the whole browser here after auth */}
      <Route path="oauth-resume" element={<OAuthResumePage />} />
      <Route element={<AppLayout />}>
        <Route index element={<LandingPage />} />
        <Route
          path="agents"
          element={
            <ProtectedRoute>
              <AgentListPage />
            </ProtectedRoute>
          }
        />
        <Route
          path="chat/:namespace/:name"
          element={
            <ProtectedRoute>
              <ChatPage />
            </ProtectedRoute>
          }
        />
      </Route>
    </Routes>
  );
};
