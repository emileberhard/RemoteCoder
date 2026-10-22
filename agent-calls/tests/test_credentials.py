import pytest
from pydantic import ValidationError

from agent_calls.carrier import load_credentials


def test_shared_source_loads_only_carrier_values_without_keychain_or_openai(tmp_path):
    source = tmp_path / "shared-env.sh"
    source.write_text(
        'export PHONE_CALL_AGENT_46ELKS_USERNAME="test-user"\n'
        'export PHONE_CALL_AGENT_46ELKS_PASSWORD="test-password"\n'
        'export AGENT_CALL_MEDIA_SECRET="abcdefghijklmnopqrstuvwxyz0123456789"\n'
    )
    credentials = load_credentials(source)
    assert credentials.username.get_secret_value() == "test-user"
    assert credentials.password.get_secret_value() == "test-password"
    assert "test-password" not in repr(credentials)


def test_missing_or_unsafe_media_credential_fails_before_network(tmp_path, monkeypatch):
    monkeypatch.delenv("AGENT_CALL_MEDIA_SECRET", raising=False)
    source = tmp_path / "shared-env.sh"
    source.write_text(
        'export PHONE_CALL_AGENT_46ELKS_USERNAME="test-user"\n'
        'export PHONE_CALL_AGENT_46ELKS_PASSWORD="test-password"\n'
    )
    with pytest.raises(ValidationError, match="not provisioned"):
        load_credentials(source)
    source.write_text(source.read_text() + 'export AGENT_CALL_MEDIA_SECRET="short"\n')
    with pytest.raises(RuntimeError, match="32 URL-safe"):
        load_credentials(source)
