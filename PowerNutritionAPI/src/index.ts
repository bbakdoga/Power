interface Env {
  USDA_API_KEY: string;
}

interface USDAFoodSearchResponse {
  foods?: USDAFood[];
  totalHits?: number;
}

interface USDANutrient {
  nutrientId?: number;
  nutrientName?: string;
  unitName?: string;
  value?: number;
}

interface USDAFood {
  fdcId: number;
  description: string;
  dataType?: string;
  brandOwner?: string;
  brandName?: string;
  gtinUpc?: string;
  servingSize?: number;
  servingSizeUnit?: string;
  foodNutrients?: USDANutrient[];
}

interface NutritionFood {
  id: string;
  name: string;
  brand?: string;
  servingSize?: number;
  servingUnit?: string;
  caloriesPer100Grams: number;
  proteinPer100Grams: number;
  carbohydratePer100Grams: number;
  fatPer100Grams: number;
}

const USDA_BASE_URL = "https://api.nal.usda.gov/fdc/v1";
const CACHE_SECONDS = 60 * 60 * 24;

export default {
  async fetch(request: Request, env: Env, context: ExecutionContext): Promise<Response> {
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders() });
    }

    if (request.method !== "GET") {
      return json({ error: "Method not allowed" }, 405);
    }

    const url = new URL(request.url);
    if (url.pathname === "/health") {
      return json({ status: "ok" });
    }

    if (url.pathname === "/v1/foods/search") {
      return searchFoods(request, env, context);
    }

    if (url.pathname === "/v1/foods/barcode") {
      return foodByBarcode(request, env, context);
    }

    return json({ error: "Not found" }, 404);
  },
} satisfies ExportedHandler<Env>;

async function searchFoods(request: Request, env: Env, context: ExecutionContext): Promise<Response> {
  const incomingURL = new URL(request.url);
  const query = normalizeQuery(incomingURL.searchParams.get("q") ?? "");

  if (query.length < 2 || query.length > 80) {
    return json({ error: "Query must contain between 2 and 80 characters" }, 400);
  }

  const pageSize = Math.min(Math.max(Number(incomingURL.searchParams.get("limit") ?? 20), 1), 25);
  const cacheURL = new URL(request.url);
  cacheURL.search = new URLSearchParams({ q: query, limit: String(pageSize), v: "3" }).toString();
  const cacheKey = new Request(cacheURL.toString(), { method: "GET" });
  const cache = caches.default;
  const cached = await cache.match(cacheKey);
  if (cached) {
    return withCacheStatus(cached, "HIT");
  }

  const usdaURL = new URL(`${USDA_BASE_URL}/foods/search`);
  usdaURL.searchParams.set("api_key", env.USDA_API_KEY);

  const fetchUSDA = () => fetch(usdaURL, {
    method: "POST",
    headers: {
      Accept: "application/json",
      "Content-Type": "application/json",
      "User-Agent": "Power-Nutrition/1.0",
    },
    body: JSON.stringify({
      query,
      pageSize: 50,
      dataType: ["Foundation", "SR Legacy", "Survey (FNDDS)", "Branded"],
    }),
  });

  let upstream = await fetchUSDA();
  for (let attempt = 1; attempt < 3 && (upstream.status === 400 || upstream.status >= 500); attempt += 1) {
    upstream = await fetchUSDA();
  }

  if (!upstream.ok) {
    const providerDetail = (await upstream.text()).slice(0, 500);
    console.error("USDA food search failed", upstream.status, providerDetail);
    if (upstream.status === 429) {
      return json({ error: "Food search is receiving too many requests. Please wait a moment and try again." }, 429);
    }
    if (upstream.status === 401 || upstream.status === 403) {
      return json({ error: `Nutrition provider rejected the API key (USDA ${upstream.status}).` }, 502);
    }
    return json({ error: `Nutrition provider unavailable (USDA ${upstream.status}).` }, 502);
  }

  const payload = await upstream.json<USDAFoodSearchResponse>();
  const foods = (payload.foods ?? [])
    .sort((left, right) => foodSearchScore(right, query) - foodSearchScore(left, query))
    .slice(0, pageSize)
    .map(normalizeFood);
  const response = json(
    { foods, total: payload.totalHits ?? foods.length },
    200,
    { "Cache-Control": `public, max-age=${CACHE_SECONDS}`, "X-Power-Cache": "MISS" },
  );

  context.waitUntil(cache.put(cacheKey, response.clone()));
  return response;
}

// Finds a USDA Branded Foods product by its GTIN/UPC. The app tries Open Food Facts first
// and calls this as a fallback, mainly for US products.
async function foodByBarcode(request: Request, env: Env, context: ExecutionContext): Promise<Response> {
  const incomingURL = new URL(request.url);
  const gtin = (incomingURL.searchParams.get("gtin") ?? "").trim();
  if (!/^\d{8,14}$/.test(gtin)) {
    return json({ error: "gtin must contain 8 to 14 digits" }, 400);
  }

  const wanted = stripLeadingZeros(gtin);
  const cacheURL = new URL(request.url);
  cacheURL.search = new URLSearchParams({ gtin: wanted, v: "1" }).toString();
  const cacheKey = new Request(cacheURL.toString(), { method: "GET" });
  const cache = caches.default;
  const cached = await cache.match(cacheKey);
  if (cached) {
    return withCacheStatus(cached, "HIT");
  }

  const usdaURL = new URL(`${USDA_BASE_URL}/foods/search`);
  usdaURL.searchParams.set("api_key", env.USDA_API_KEY);
  const upstream = await fetch(usdaURL, {
    method: "POST",
    headers: {
      Accept: "application/json",
      "Content-Type": "application/json",
      "User-Agent": "Power-Nutrition/1.0",
    },
    body: JSON.stringify({ query: wanted, pageSize: 25, dataType: ["Branded"] }),
  });

  if (!upstream.ok) {
    console.error("USDA barcode lookup failed", upstream.status, (await upstream.text()).slice(0, 500));
    if (upstream.status === 429) {
      return json({ error: "Food search is receiving too many requests. Please wait a moment and try again." }, 429);
    }
    return json({ error: `Nutrition provider unavailable (USDA ${upstream.status}).` }, 502);
  }

  const payload = await upstream.json<USDAFoodSearchResponse>();
  const match = (payload.foods ?? []).find((food) => stripLeadingZeros(food.gtinUpc ?? "") === wanted);

  const response = match
    ? json({ food: normalizeFood(match) }, 200, {
      "Cache-Control": `public, max-age=${CACHE_SECONDS}`,
      "X-Power-Cache": "MISS",
    })
    : json({ error: "Product not found" }, 404, {
      "Cache-Control": `public, max-age=${CACHE_SECONDS}`,
      "X-Power-Cache": "MISS",
    });

  context.waitUntil(cache.put(cacheKey, response.clone()));
  return response;
}

function stripLeadingZeros(value: string): string {
  return value.replace(/\D/g, "").replace(/^0+/, "");
}

function normalizeFood(food: USDAFood): NutritionFood {
  return {
    id: String(food.fdcId),
    name: titleCase(food.description),
    brand: food.brandName ?? food.brandOwner,
    servingSize: food.servingSize,
    servingUnit: food.servingSizeUnit,
    caloriesPer100Grams: nutrient(food.foodNutrients, [1008, 2047, 2048], ["energy"], "kcal"),
    proteinPer100Grams: nutrient(food.foodNutrients, [1003], ["protein"]),
    carbohydratePer100Grams: nutrient(food.foodNutrients, [1005], ["carbohydrate"]),
    fatPer100Grams: nutrient(food.foodNutrients, [1004], ["total lipid", "fat"]),
  };
}

function foodSearchScore(food: USDAFood, query: string): number {
  const description = food.description.toLowerCase().trim();
  const dataType = food.dataType?.toLowerCase() ?? "";
  let score = 0;

  if (description === query) score += 100;
  else if (description.startsWith(query)) score += 55;
  else if (description.includes(query)) score += 25;

  if (dataType.includes("foundation")) score += 40;
  else if (dataType.includes("sr legacy")) score += 35;
  else if (dataType.includes("survey")) score += 25;
  else if (dataType.includes("branded")) score -= 5;

  if (!food.brandOwner) score += 10;
  return score;
}

function nutrient(
  items: USDANutrient[] | undefined,
  ids: number[],
  names: string[],
  preferredUnit?: string,
): number {
  const candidates = items ?? [];
  const itemByID = candidates.find((candidate) => ids.includes(candidate.nutrientId ?? -1));
  const itemByName = candidates.find((candidate) => {
    const name = candidate.nutrientName?.toLowerCase() ?? "";
    const unit = candidate.unitName?.toLowerCase() ?? "";
    return names.some((needle) => name.includes(needle)) && (!preferredUnit || unit === preferredUnit);
  });
  const item = itemByID ?? itemByName;
  return Math.max(item?.value ?? 0, 0);
}

function normalizeQuery(value: string): string {
  return value.trim().toLowerCase().replace(/\s+/g, " ");
}

function titleCase(value: string): string {
  return value
    .toLowerCase()
    .replace(/(^|\s|[-(])\p{L}/gu, (character) => character.toUpperCase());
}

function json(body: unknown, status = 200, additionalHeaders: HeadersInit = {}): Response {
  return Response.json(body, {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      ...corsHeaders(),
      ...additionalHeaders,
    },
  });
}

function corsHeaders(): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
    "X-Content-Type-Options": "nosniff",
  };
}

function withCacheStatus(response: Response, status: string): Response {
  const headers = new Headers(response.headers);
  headers.set("X-Power-Cache", status);
  return new Response(response.body, { status: response.status, headers });
}
