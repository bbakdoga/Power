# Power Nutrition API

Cloudflare Worker that keeps the USDA FoodData Central key outside the iOS app.

## Endpoints

- `GET /v1/foods/search?q=chicken&limit=20` searches all USDA data types.
- `GET /v1/foods/barcode?gtin=0123456789012` finds a USDA Branded Foods product by its
  GTIN/UPC. Returns `{ "food": … }`, or 404 with `{ "error": "Product not found" }`.
  The app calls this only after Open Food Facts had no nutrition values for the barcode.

## Local setup

1. Create a free FoodData Central API key at https://fdc.nal.usda.gov/api-key-signup/
2. Run `npm install`.
3. Create `.dev.vars` with `USDA_API_KEY=your-development-key`.
4. Run `npm run dev`.

## Deployment

1. Run `npx wrangler login`.
2. Run `npx wrangler secret put USDA_API_KEY`.
3. Run `npm run deploy`.
4. Copy the deployed `workers.dev` URL into `NutritionAPI.baseURL` in the iOS project.

Never commit the USDA key or `.dev.vars`.
