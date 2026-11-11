import pytest

from remotecoder_tools import mac_bench


def summary(posted, moved):
    return {"input": {"postedPixels": posted, "movedPixels": moved}}


@pytest.mark.parametrize(("posted", "moved"), [(0, 0), (0, 10460), (12576, 126), (12576, 11000)])
def test_answered_or_absent_gestures_pass(posted, moved):
    assert mac_bench.unanswered_gestures(summary(posted, moved), None) is None


def test_unanswered_gestures_name_responsive_scrolling():
    error = mac_bench.unanswered_gestures(summary(12576, 2), "markdownCache")
    assert error is not None
    assert "posted 12576 px" in error and "moved 2 px" in error
    assert "--disable responsiveScrolling" in error


def test_unanswered_gestures_with_responsive_scrolling_disabled_omit_the_hint():
    error = mac_bench.unanswered_gestures(summary(12576, 0), "markdownCache,responsiveScrolling")
    assert error is not None
    assert "responsiveScrolling" not in error
