def require_executed_tests(executed: int, selected: str):
    if executed == 0:
        raise ValueError(
            f"No test execution was verified for filter {selected!r}; check the suite/test name."
        )
