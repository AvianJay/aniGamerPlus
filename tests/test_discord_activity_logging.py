"""Viewing capabilities must not appear in console or file access logs."""
import logging
from urllib.parse import parse_qs, urlsplit

import pytest

from Dashboard.Server import _ActivityGrantLogFilter


@pytest.mark.parametrize('query', [
    'id=101&ag=test-capability',
    'ag=test-capability&id=101',
    'id=101&%61%67=test-capability&ag=second-capability',
])
def test_access_log_redacts_all_guest_capabilities(query):
    record = logging.LogRecord('uvicorn.access', logging.INFO, '', 0,
                               '%s - "%s %s HTTP/%s" %d',
                               ('127.0.0.1', 'GET', '/get_video.mp4?' + query, '1.1', 200), None)
    assert _ActivityGrantLogFilter().filter(record)
    rendered = record.getMessage()
    assert 'test-capability' not in rendered and 'second-capability' not in rendered
    values = parse_qs(urlsplit(record.args[2]).query)
    assert values['id'] == ['101']
    assert all(value == '[redacted]' for value in values['ag'])


def test_access_log_preserves_ordinary_request_fields():
    args = ('127.0.0.1', 'GET', '/get_video.mp4?id=101&res=1080', '1.1', 206)
    record = logging.LogRecord('uvicorn.access', logging.INFO, '', 0,
                               '%s - "%s %s HTTP/%s" %d', args, None)
    assert _ActivityGrantLogFilter().filter(record)
    assert record.args == args
