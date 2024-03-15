# Senacor Blog: Tackling Canary Deployments with Google Cloud Load Balancing and Cloud Run

This repository demonstrates an traffic distribution approach with support for canary deployments for microservices running on Cloud Run using Google Cloud Load Balancing.

## Try it out

- `curl https://example.com/first` -> Request sent to `first-ms`
- `curl -H "canary-first-ms: canary" https://example.com/first` -> Request sent to `first-ms[canary]`
- `curl https://example.com/second` -> Request sent to `second-ms`
- `curl https://example.com/other` -> Request sent to `default-ms`
