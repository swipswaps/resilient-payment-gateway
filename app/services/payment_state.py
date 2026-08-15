"""Payment workflow state machine.
References:
- python-statemachine: https://github.com/fgmacedo/python-statemachine
- RFC 2119: "MAY" for state definitions.
"""
from statemachine import StateMachine, State


class PaymentWorkflow(StateMachine):
    draft = State("draft", initial=True)
    pending = State("pending")
    completed = State("completed")
    failed = State("failed")

    authorize = draft.to(pending)
    capture = pending.to(completed)
    decline = pending.to(failed)
    refund = completed.to(draft)

    def __init__(self, payment_id: str, amount: float, currency: str, **kwargs):
        self.payment_id = payment_id
        self.amount = amount
        self.currency = currency
        self.failure_reason = None
        super().__init__(**kwargs)

    def decline(self, reason: str = "Payment declined"):
        self.failure_reason = reason
        super().decline()
