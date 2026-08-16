import { useState, useEffect } from 'react';

const API_BASE_URL = import.meta.env.VITE_API_BASE_URL || 'http://localhost:8000';

function App() {
  const [paymentId, setPaymentId] = useState('tx_001');
  const [amount, setAmount] = useState(10);
  const [provider, setProvider] = useState('mock_payment_provider');
  const [currency, setCurrency] = useState('USD');
  const [response, setResponse] = useState(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState(null);
  const [apiStatus, setApiStatus] = useState('checking...');

  useEffect(() => {
    const checkApi = async () => {
      try {
        const res = await fetch(`${API_BASE_URL}/api/v1/payments/execute`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ payment_id: 'health_check', amount: 0.01, provider: 'mock_payment_provider', currency: 'USD' })
        });
        setApiStatus(res.ok ? '✅ Connected' : `⚠️ Status ${res.status}`);
      } catch (e) { setApiStatus('❌ Cannot reach backend'); }
    };
    checkApi();
  }, []);

  const handleSubmit = async (e) => {
    e.preventDefault();
    setLoading(true); setError(null); setResponse(null);
    try {
      const res = await fetch(`${API_BASE_URL}/api/v1/payments/execute`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-Idempotency-Key': `idemp-${Date.now()}` },
        body: JSON.stringify({ payment_id: paymentId, amount: Number(amount), provider, currency })
      });
      const data = await res.json();
      if (res.ok) setResponse(data);
      else setError(data.detail || `HTTP ${res.status}`);
    } catch (err) { setError(`Network error: ${err.message}`); }
    setLoading(false);
  };

  return (
    <div style={{ padding: '2rem', maxWidth: '600px', margin: '0 auto', fontFamily: 'sans-serif' }}>
      <h1>💳 Payment Gateway</h1>
      <p style={{ color: apiStatus.includes('✅') ? 'green' : 'red' }}>API: {apiStatus}</p>
      <form onSubmit={handleSubmit} style={{ display: 'flex', flexDirection: 'column', gap: '1rem' }}>
        <input value={paymentId} onChange={(e) => setPaymentId(e.target.value)} placeholder="Payment ID" required />
        <input type="number" step="0.01" value={amount} onChange={(e) => setAmount(Number(e.target.value))} placeholder="Amount" required min="0.01" />
        <input value={provider} onChange={(e) => setProvider(e.target.value)} placeholder="Provider (mock_payment_provider)" />
        <input value={currency} onChange={(e) => setCurrency(e.target.value)} placeholder="Currency (USD)" />
        <button type="submit" disabled={loading} style={{ padding: '0.75rem', background: loading ? '#ccc' : '#0066cc', color: 'white', border: 'none', borderRadius: '4px' }}>{loading ? 'Processing...' : '💳 Pay Now'}</button>
      </form>
      {error && <div style={{ color: '#c00', marginTop: '1rem' }}><strong>Error:</strong> {error}</div>}
      {response && <pre style={{ background: '#f5f5f5', padding: '0.75rem', marginTop: '1rem', borderRadius: '4px' }}>{JSON.stringify(response, null, 2)}</pre>}
    </div>
  );
}
export default App;
