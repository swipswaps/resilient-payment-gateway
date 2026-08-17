import { test, expect } from '@playwright/test';

test('payment flow works', async ({ page }) => {
  await page.goto('/');
  
  // Wait for form
  await expect(page.locator('input[placeholder="Payment ID"]')).toBeVisible();
  
  // Fill form
  await page.fill('input[placeholder="Payment ID"]', 'ci_test_001');
  await page.fill('input[placeholder="Amount"]', '10.00');
  await page.fill('input[placeholder="Provider (mock_payment_provider)"]', 'mock_payment_provider');
  await page.fill('input[placeholder="Currency (USD)"]', 'USD');
  
  // Submit
  await page.click('button:has-text("Pay Now")');
  
  // Wait for response
  await expect(page.locator('pre')).toBeVisible();
  const responseText = await page.textContent('pre');
  const response = JSON.parse(responseText);
  expect(response.current_state).toBe('completed');
});
