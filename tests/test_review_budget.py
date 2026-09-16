from hooks.review_packet import ReviewState


def test_protocol_repair_is_allowed_once():
    state = ReviewState(
        "abc",
        semantic_review_done=True,
        protocol_repairs=0,
        independent_reviews=0,
    )
    assert state.can_retry_protocol()
    state.protocol_repairs += 1
    assert not state.can_retry_protocol()


def test_independent_review_is_one_shot():
    state = ReviewState(
        "abc",
        semantic_review_done=True,
        protocol_repairs=0,
        independent_reviews=1,
    )
    assert not state.can_start_independent()


def test_protocol_failure_does_not_claim_code_failure():
    message = ReviewState(
        "abc",
        semantic_review_done=True,
        protocol_repairs=1,
        independent_reviews=0,
    ).protocol_failure_message()
    assert "协议问题" in message
    assert "代码问题" in message
