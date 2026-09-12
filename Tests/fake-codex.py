#!/usr/bin/python3
"""Synthetic protocol peer. Never accesses credentials or network."""
import json
import os
import sys
import time

mode = os.environ.get('QUOTA_FAKE_MODE', 'success')
request = json.loads(sys.stdin.readline())
assert request['method'] == 'initialize' and request['id'] == 1
assert 'analytics.enabled=false' in sys.argv
assert 'otel.metrics_exporter="none"' in sys.argv
if mode == 'timeout':
    time.sleep(10)
    sys.exit(0)
print(json.dumps({'id': 1, 'result': {'userAgent': 'synthetic'}}), flush=True)
assert json.loads(sys.stdin.readline())['method'] == 'initialized'
request = json.loads(sys.stdin.readline())
assert request['method'] == 'account/rateLimits/read' and request['id'] == 2
assert request['params']['excludeResetCreditDetails'] is True
print(json.dumps({'method': 'warning', 'params': {'message': 'ignore synthetic event'}}), flush=True)
if mode == 'error':
    print(json.dumps({'id': 2, 'error': {'code': -1, 'message': '401 unauthorized SECRET'}}), flush=True)
else:
    reply = json.dumps({'id': 2, 'result': {'rateLimits': {'primary': {'usedPercent': 36, 'windowDurationMins': 10080}}}})
    sys.stdout.write(reply[:30])
    sys.stdout.flush()
    time.sleep(.05)
    sys.stdout.write(reply[30:] + '\n')
    sys.stdout.flush()
time.sleep(10)
