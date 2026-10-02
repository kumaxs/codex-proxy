import importlib.util
import json
import pathlib
import queue
import ssl
import threading
import unittest
from unittest.mock import patch

path = pathlib.Path(__file__).parents[1] / 'bin/pages-realtime-proxy.py'
spec = importlib.util.spec_from_file_location('pages_proxy', path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

PARAMS = {'endpoint': 'https://chatgpt.com/backend-api/pages/realtime-broker/u8/ws',
          'pageId': 'page_example', 'token': 'test-token'}

class EndpointTests(unittest.TestCase):
    def test_official_broker_and_grant(self):
        url, protocol = module.endpoint(dict(PARAMS, authorizationGrant='test grant'))
        self.assertTrue(url.startswith('wss://chatgpt.com/'))
        self.assertIn('authorization_grant=test+grant', url)
        self.assertEqual(protocol, 'pages-realtime-room.page_example')

    def test_official_gateway(self):
        url, _ = module.endpoint(dict(PARAMS, endpoint='wss://pages-realtime.gateway.us.api.openai.com/ws'))
        self.assertTrue(url.startswith('wss://pages-realtime.gateway.us.api.openai.com/ws?'))

    def test_reject_foreign_or_insecure_endpoint(self):
        for url in ['wss://example.com/ws', 'ws://chatgpt.com/backend-api/pages/realtime-broker/u8/ws',
                    'wss://chatgpt.com.evil.test/backend-api/pages/realtime-broker/u8/ws',
                    'wss://user@chatgpt.com/backend-api/pages/realtime-broker/u8/ws',
                    'wss://chatgpt.com:8443/backend-api/pages/realtime-broker/u8/ws',
                    'wss://chatgpt.com/backend-api/pages/realtime-broker/u08/ws',
                    'wss://chatgpt.com/backend-api/pages/realtime-broker/u8/ws#x']:
            with self.subTest(url=url), self.assertRaises(ValueError):
                module.endpoint(dict(PARAMS, endpoint=url))

    def test_reject_invalid_credentials(self):
        for change in [{'token': ''}, {'token': 'x' * 32769}, {'authorizationGrant': 42}, {'pageId': '../other'}]:
            with self.subTest(change=list(change)), self.assertRaises(ValueError):
                module.endpoint(dict(PARAMS, **change))

    def test_proxy_must_be_explicit(self):
        self.assertEqual(module.proxy_address('http://127.0.0.1:29758'), ('127.0.0.1', 29758))
        for url in ['socks5://localhost:1', 'http://u:p@localhost:1', 'http://localhost:1/path']:
            with self.assertRaises(ValueError): module.proxy_address(url)

class FakeSocket:
    def __init__(self): self.items = iter(['{"type":"test"}', ''])
    def settimeout(self, value): pass
    def recv(self): return next(self.items)
    def close(self, **kwargs): pass

class TransportTests(unittest.TestCase):
    def helper(self):
        h = module.PagesProxy.__new__(module.PagesProxy)
        h.proxy_host, h.proxy_port = '127.0.0.1', 29758
        h.messages, h.running = queue.Queue(), threading.Event()
        h.running.set(); h.tls = ssl.create_default_context()
        return h

    def test_frames_and_tls_policy(self):
        h = self.helper()
        with patch.object(module.websocket, 'create_connection', return_value=FakeSocket()) as connect:
            h.upstream(('session', 1, '1'), PARAMS, {'stop': threading.Event()})
        events = [h.messages.get_nowait()[1] for _ in range(3)]
        self.assertEqual([e['type'] for e in events], ['open', 'message', 'close'])
        self.assertEqual(events[-1]['code'], 1000)
        kw = connect.call_args.kwargs
        self.assertTrue(kw['suppress_origin'])
        self.assertEqual(kw['http_proxy_port'], 29758)
        self.assertEqual(kw['redirect_limit'], 0)
        self.assertTrue(kw['sslopt']['context'].check_hostname)
        self.assertEqual(kw['sslopt']['context'].verify_mode, ssl.CERT_REQUIRED)

    def test_failure_does_not_leak_signed_url(self):
        h = self.helper()
        with patch.object(module.websocket, 'create_connection', side_effect=RuntimeError('token=SECRET')):
            h.upstream(('session', 1, '1'), PARAMS, {'stop': threading.Event()})
        events = [h.messages.get_nowait()[1] for _ in range(2)]
        self.assertNotIn('SECRET', json.dumps(events))
        self.assertEqual(events[-1]['code'], 1006)

    def test_subsequent_connection_after_failure(self):
        h = self.helper()
        with patch.object(module.websocket, 'create_connection', side_effect=[OSError('offline'), FakeSocket()]):
            h.upstream(('session', 1, '1'), PARAMS, {'stop': threading.Event()})
            h.upstream(('session', 1, '2'), PARAMS, {'stop': threading.Event()})
        events = []
        while not h.messages.empty(): events.append(h.messages.get_nowait()[1]['type'])
        self.assertEqual(events, ['error', 'close', 'open', 'message', 'close'])

    def test_cancelled_connect_does_not_emit_open(self):
        h = self.helper(); stopped = threading.Event(); stopped.set()
        with patch.object(module.websocket, 'create_connection', return_value=FakeSocket()):
            h.upstream(('session', 1, '1'), PARAMS, {'stop': stopped})
        self.assertEqual(h.messages.get_nowait()[1]['type'], 'close')
        self.assertTrue(h.messages.empty())

    def test_send_failure_is_local_to_one_page(self):
        h = self.helper()
        class ClosedSocket:
            def send(self, content): raise OSError('connection closed token=SECRET')
        key = ('session', 1, '1')
        h.sessions = {'session': {}}
        h.channels = {key: {'sock': ClosedSocket()}, ('other', 2, '2'): {}}
        h.event({'method': 'Runtime.bindingCalled', 'sessionId': 'session', 'params': {
            'name': module.BINDING, 'executionContextId': 1,
            'payload': json.dumps({'action': 'send', 'id': '1', 'data': 'test'})}})
        events = [h.messages.get_nowait()[1] for _ in range(2)]
        self.assertEqual([e['type'] for e in events], ['error', 'close'])
        self.assertNotIn('SECRET', json.dumps(events))
        self.assertTrue(h.running.is_set())
        self.assertIn(('other', 2, '2'), h.channels)

if __name__ == '__main__':
    unittest.main()
