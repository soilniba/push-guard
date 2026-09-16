import pytest

from hooks.review_policy import ReviewPolicy


def test_default_profile_is_balanced():
    decision = ReviewPolicy.from_environment({}).classify(
        ["app/service.py"], "return value", ""
    )
    assert decision.profile == "balanced"


def test_profile_is_manual_and_unknown_value_fails_closed():
    policy = ReviewPolicy.from_environment({"PUSH_GUARD_PROFILE": "strict"})
    assert policy.profile == "strict"

    with pytest.raises(ValueError):
        ReviewPolicy.from_environment({"PUSH_GUARD_PROFILE": "auto-model-score"})


def test_docs_only_diff_is_l0_without_model_review():
    decision = ReviewPolicy.from_environment({}).classify(
        ["docs/README.md"], "+说明", ""
    )
    assert decision.tier == "L0"
    assert decision.review_required is False


def test_hook_and_target_scope_changes_are_l2():
    decision = ReviewPolicy.from_environment({}).classify(
        ["hooks/check_push_guard.py", "app/router.py"],
        "+subprocess.run git push",
        "",
    )
    assert decision.tier == "L2"
    assert decision.independent_reviewer_required is False


def test_large_normal_business_diff_is_not_automatically_independent():
    decision = ReviewPolicy.from_environment({}).classify(
        [f"app/module_{i}.py" for i in range(6)],
        "\n".join("+value = 1" for _ in range(500)),
        "",
    )
    assert decision.tier in {"L1", "L2"}
    assert decision.independent_reviewer_required is False
