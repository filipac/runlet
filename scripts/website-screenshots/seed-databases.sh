#!/bin/sh
# Seeds, or removes, the demo data that the website's MongoDB shot reads (#246): the `shop_demo`
# database in the disposable runlet-fixtures `mongo` container (scripts/setup-fixtures.sh
# databases). shoot.sh runs `seed` before shooting and `clean` when it ends.
#
#   scripts/website-screenshots/seed-databases.sh seed|clean
#
# `seed` prints the container's published port. It never touches other containers or databases,
# and pulls no images.
set -e
MONGO="$(docker compose -p runlet-fixtures ps -q mongo 2>/dev/null || true)"
if [ -z "$MONGO" ]; then
  echo "The runlet-fixtures mongo container isn't running; start it with scripts/setup-fixtures.sh databases." >&2
  exit 1
fi
mongosh() { docker exec -i "$MONGO" mongosh --quiet -u runlet -p runlet-fixture --authenticationDatabase admin "$@"; }

case "$1" in
  clean)
    mongosh --eval 'db.getSiblingDB("shop_demo").dropDatabase()' </dev/null >/dev/null
    ;;
  seed)
    mongosh >/dev/null <<'MONGO'
const shop = db.getSiblingDB("shop_demo");
shop.dropDatabase();
const products = ["Organic cotton tee", "Enamel camp mug", "Canvas tote bag", "Merino socks (2 pack)",
  "Steel water bottle", "Dot grid notebook", "Wool beanie", "Enamel pin set"];
shop.products.insertMany(products.map((name, i) => ({ name, price: NumberDecimal(((i * 7) % 20 + 12).toFixed(2)), in_stock: i % 4 !== 3 })));
const titles = ["Soft and well made", "Keeps coffee hot", "Holds everything", "Warmest socks I own",
  "No leaks so far", "Great paper", "Runs a little small", "Lovely colours", "Fast delivery", "Gift for my sister"];
const ratings = [5, 4, 5, 3, 4, 5, 2, 4, 5];
const reviews = [];
for (let i = 0; i < 48; i++) {
  reviews.push({ product: products[i % products.length], rating: NumberInt(ratings[i % ratings.length]),
    title: titles[i % titles.length], verified: i % 5 !== 2, helpful: NumberInt((i * 7) % 23),
    posted_at: new Date(Date.UTC(2026, 8, 1 + (i % 30), 8 + (i % 11), (i * 13) % 60)) });
}
shop.reviews.insertMany(reviews);
shop.carts.insertOne({ _id: 1042, customer: "ada@example.com", items: [{ sku: "TEE-ORG", qty: NumberInt(2) }, { sku: "MUG-ENM", qty: NumberInt(1) }] });
MONGO
    docker port "$MONGO" 27017 | head -1 | sed 's/.*://'
    ;;
  *)
    echo "usage: $0 seed|clean" >&2
    exit 2
    ;;
esac
