"""Payment exception hierarchy for retry logic."""
class PaymentProviderError(Exception):
    pass

class TransientPaymentError(PaymentProviderError):
    pass

class PermanentPaymentError(PaymentProviderError):
    pass
