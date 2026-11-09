public with sharing class ExternalOrderClient {

    // Authentication, base URL and certificates live in the Supplier_PO_API Named Credential. Nothing
    // secret is read, built or logged here.
    @TestVisible private static final String ENDPOINT = 'callout:Supplier_PO_API/purchase-orders';
    private static final Integer TIMEOUT_MS = 30000;
    private static final List<String> CONFIRMATION_KEYS = new List<String>{ 'orderId', 'id', 'externalId' };

    public class OrderResponse {
        public Boolean success = false;
        // True for failures that may succeed on a later attempt (timeouts, throttling, 5xx).
        public Boolean retryable = false;
        public Integer statusCode;
        public String externalOrderId;
        public String message;
    }

    // Sends one purchase order. The Idempotency-Key header lets the supplier recognise a repeated
    // attempt of the same order. Success is reported only when the supplier returns an order
    // confirmation id; a 2xx without one is not treated as a confirmed dispatch.
    public static OrderResponse submitOrder(Purchase_Order__c po) {
        try {
            HttpRequest request = new HttpRequest();
            request.setEndpoint(ENDPOINT);
            request.setMethod('POST');
            request.setTimeout(TIMEOUT_MS);
            request.setHeader('Content-Type', 'application/json');
            request.setHeader('Accept', 'application/json');
            request.setHeader('Idempotency-Key', po.Idempotency_Key__c);
            request.setBody(buildPayload(po));
            HttpResponse response = new Http().send(request);
            return parseResponse(response.getStatusCode(), response.getBody());
        } catch (CalloutException e) {
            OrderResponse failure = new OrderResponse();
            failure.retryable = true;
            failure.message = 'The supplier endpoint could not be reached: ' + e.getMessage();
            return failure;
        } catch (Exception e) {
            OrderResponse failure = new OrderResponse();
            failure.message = 'Dispatch request failed: ' + e.getMessage();
            return failure;
        }
    }

    @TestVisible
    private static String buildPayload(Purchase_Order__c po) {
        List<Map<String, Object>> lines = new List<Map<String, Object>>();
        for (Purchase_Order_Line__c line : po.Purchase_Order_Lines__r) {
            lines.add(new Map<String, Object>{
                'product' => line.Product__r == null ? null : line.Product__r.Name,
                'quantity' => line.Quantity_Ordered__c,
                'unitPrice' => line.Unit_Price__c
            });
        }
        return JSON.serialize(new Map<String, Object>{
            'orderNumber' => po.Name,
            'idempotencyKey' => po.Idempotency_Key__c,
            'supplier' => po.Supplier__r == null ? null : po.Supplier__r.Name,
            'orderDate' => po.Order_Date__c,
            'expectedDelivery' => po.Expected_Delivery__c,
            'totalAmount' => po.Total_Amount__c,
            'lines' => lines
        });
    }

    @TestVisible
    private static OrderResponse parseResponse(Integer statusCode, String body) {
        OrderResponse result = new OrderResponse();
        result.statusCode = statusCode;
        if (statusCode >= 200 && statusCode < 300) {
            result.externalOrderId = extractConfirmation(body);
            if (String.isBlank(result.externalOrderId)) {
                result.message = 'The supplier answered HTTP ' + statusCode + ' without an order confirmation id, so the dispatch is not confirmed.';
            } else {
                result.success = true;
                result.message = 'Dispatch confirmed by the supplier.';
            }
            return result;
        }
        result.retryable = statusCode == 408 || statusCode == 425 || statusCode == 429 || statusCode >= 500;
        result.message = 'The supplier endpoint returned HTTP ' + statusCode + (result.retryable ? ' (temporary failure).' : ' (order rejected).');
        return result;
    }

    private static String extractConfirmation(String body) {
        if (String.isBlank(body)) return null;
        try {
            Object parsed = JSON.deserializeUntyped(body);
            if (!(parsed instanceof Map<String, Object>)) return null;
            Map<String, Object> values = (Map<String, Object>) parsed;
            for (String key : CONFIRMATION_KEYS) {
                Object value = values.get(key);
                if (value != null && String.isNotBlank(String.valueOf(value))) return String.valueOf(value).trim();
            }
        } catch (JSONException e) {
            return null;
        }
        return null;
    }
}
