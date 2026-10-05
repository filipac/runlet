<?php

declare(strict_types=1);

/*
 * Values mode for Eloquent models (#307): what a model holds, not its internals.
 *
 * ValueNormalizer uses this trait in its walk for `modelValues` (see
 * ValueNormalizer::normalizeViews()). In that walk:
 *
 * - a model becomes its class, its key, its attributes (changed ones carry their original
 *   value, hidden ones are marked), and its loaded relations, themselves in Values form;
 * - an Eloquent collection, a Support collection holding a model, and a paginator of them
 *   become their items, with the count (and the paginator's page and total);
 * - an array whose first value is a model is a list of models.
 *
 * Lists of models get `maxRows` rows instead of `maxChildren`, within the same node and byte
 * budget, and a row the budget would cut in the middle is left out and counted as omitted,
 * so the Tree and the Table show the same whole rows.
 *
 * Only properties are read, through get_mangled_object_vars() (attributes, original,
 * relations, exists, hidden, visible, primaryKey; a collection's or paginator's items, page,
 * and total). No accessor, mutator, cast, getAttribute(), toArray(), or __toString() runs, so
 * nothing in the application's code runs to show a value.
 *
 * This file must stay compatible with PHP 7.4 syntax and runtime (no constants in traits).
 */

namespace RunletRunner;

trait ModelValues
{
    /** @var bool Encode Eloquent models by their values (the walk for `modelValues`). */
    private $valuesMode = false;
    /** @var bool The values walk encoded a model, or a collection, paginator, or list of models. */
    private $sawModels = false;
    /** @var int Rows of a list of models: a collection, a paginator, or an array of models. */
    private $maxRows = 1000;
    /** @var int How many models' values the walk is inside: a date there is only its summary. */
    private $insideModel = 0;

    /**
     * The Values node of an Eloquent model, collection, or paginator; null for any other object,
     * which keeps its usual encoding.
     *
     * @param array<string, mixed> $node the object node so far (id, type, className, referenceId)
     * @return array<string, mixed>|null
     */
    private function modelValuesNode(array $node, object $value, int $depth): ?array
    {
        if ($this->insideModel > 0 && $value instanceof \DateTimeInterface) {
            // A date a model holds is its moment, as the Object view summarizes it, without
            // Carbon's twenty-odd settings: Values rows stay small.
            $node['summary'] = $value->format('Y-m-d H:i:s.u P') . ' (' . $value->getTimezone()->getName() . ')';

            return $node;
        }
        if (is_a($value, 'Illuminate\Database\Eloquent\Model')) {
            $this->sawModels = true;

            return $this->modelNode($node, $value, $depth);
        }
        $list = self::modelListOf($value);
        if ($list === null) {
            return null;
        }
        $this->sawModels = true;
        [$items, $meta] = $list;
        $node['collection'] = $meta;
        $node['count'] = count($items);
        if ($items === []) {
            $node['entries'] = [];

            return $node;
        }
        if ($depth >= $this->maxDepth) {
            $node['truncation'] = ['reason' => 'depth', 'omitted' => count($items)];

            return $node;
        }

        return $this->modelRows($node, $items, $depth);
    }

    /**
     * Whether an array is a list of models in the values walk: its first value is a model.
     *
     * @param array<mixed> $value
     */
    private function isModelList(array $value): bool
    {
        if (!$this->valuesMode) {
            return false;
        }
        foreach ($value as $item) {
            if (is_a($item, 'Illuminate\Database\Eloquent\Model')) {
                $this->sawModels = true;

                return true;
            }

            return false;
        }

        return false;
    }

    /**
     * The rows of a list of models (a collection's or paginator's items, or an array of
     * models), up to `maxRows`. A row the budget would cut is left out: every row shown is whole.
     *
     * @param array<string, mixed> $node
     * @param array<mixed> $items
     * @return array<string, mixed>
     */
    private function modelRows(array $node, array $items, int $depth): array
    {
        $count = count($items);
        $entries = [];
        $shown = 0;
        foreach ($items as $key => $item) {
            if ($shown >= $this->maxRows || $this->overBudget()) {
                break;
            }
            $exceededBefore = $this->budgetExceeded;
            $entry = ['key' => is_int($key) ? (string) $key : $this->keyString((string) $key), 'keyType' => is_int($key) ? 'int' : 'string'];
            $entry['value'] = $this->node($item, $depth + 1);
            if ($shown > 0 && !$exceededBefore && $this->budgetExceeded) {
                // The budget ran out inside this row: leave all of it out rather than half of it.
                break;
            }
            $entries[] = $entry;
            $shown++;
        }
        $node['entries'] = $entries;
        if ($shown < $count) {
            $node['truncation'] = $this->budgetExceeded
                ? ['reason' => 'budget', 'omitted' => $count - $shown]
                : ['reason' => 'rows', 'omitted' => $count - $shown, 'limit' => $this->maxRows];
        }

        return $node;
    }

    /**
     * A model: its key and state in `model`, then its attributes and its loaded relations.
     *
     * @param array<string, mixed> $node
     * @return array<string, mixed>
     */
    private function modelNode(array $node, object $model, int $depth): array
    {
        $properties = self::propertiesOf($model);
        $attributes = self::arrayProperty($properties, 'attributes');
        $original = self::arrayProperty($properties, 'original');
        $relations = self::arrayProperty($properties, 'relations');
        $hidden = array_flip(array_filter(self::arrayProperty($properties, 'hidden'), 'is_string'));
        $visible = array_flip(array_filter(self::arrayProperty($properties, 'visible'), 'is_string'));
        $exists = ($properties['exists'] ?? false) === true;

        $info = ['exists' => $exists];
        $keyName = $properties["\0*\0primaryKey"] ?? null;
        if (is_string($keyName) && $keyName !== '') {
            $info['keyName'] = $keyName;
            // laravel-mongodb names the key `id` and may still hold it as `_id`.
            $keyAttribute = array_key_exists($keyName, $attributes) ? $keyName : (array_key_exists('_id', $attributes) ? '_id' : null);
            if ($keyAttribute !== null) {
                $key = self::keyText($attributes[$keyAttribute]);
                if ($key !== null) {
                    $info['key'] = $key;
                }
            }
        }
        // A new model's attributes are all new: only a model with something to compare is marked.
        $compares = $exists || $original !== [];
        $dirty = [];
        if ($compares) {
            foreach ($attributes as $name => $attribute) {
                if (!array_key_exists($name, $original) || !self::sameValue($attribute, $original[$name], 0)) {
                    $dirty[$name] = true;
                }
            }
            if ($dirty !== []) {
                $info['dirty'] = count($dirty);
            }
        }
        $node['model'] = $info;

        $count = count($attributes) + count($relations);
        $node['count'] = $count;
        if ($count === 0) {
            $node['entries'] = [];

            return $node;
        }
        if ($depth >= $this->maxDepth) {
            $node['truncation'] = ['reason' => 'depth', 'omitted' => $count];

            return $node;
        }

        $this->insideModel++;
        try {
            [$entries, $shown] = $this->modelEntries($attributes, $original, $relations, $dirty, $hidden, $visible, $depth);
        } finally {
            $this->insideModel--;
        }
        $node['entries'] = $entries;
        if ($shown < $count) {
            $node['truncation'] = ['reason' => $this->budgetExceeded ? 'budget' : 'children', 'omitted' => $count - $shown];
        }

        return $node;
    }

    /**
     * A model's attribute entries (hidden and changed ones marked, a changed one with its
     * original value), then its relations; and how many were shown.
     *
     * @param array<mixed> $attributes
     * @param array<mixed> $original
     * @param array<mixed> $relations
     * @param array<string, bool> $dirty
     * @param array<string, int> $hidden
     * @param array<string, int> $visible
     * @return array{0: array<int, array<string, mixed>>, 1: int}
     */
    private function modelEntries(array $attributes, array $original, array $relations, array $dirty, array $hidden, array $visible, int $depth): array
    {
        $entries = [];
        $shown = 0;
        foreach ($attributes as $name => $attribute) {
            if ($shown >= $this->maxChildren || $this->overBudget()) {
                break;
            }
            $shown++;
            $name = (string) $name;
            $entry = ['key' => $this->keyString($name), 'keyType' => 'attribute'];
            if (isset($hidden[$name]) || ($visible !== [] && !isset($visible[$name]))) {
                $entry['hidden'] = true;
            }
            if (isset($dirty[$name])) {
                $entry['dirty'] = true;
                if (array_key_exists($name, $original)) {
                    $entry['original'] = $this->node($original[$name], $depth + 1);
                }
            }
            $entry['value'] = $this->node($attribute, $depth + 1);
            $entries[] = $entry;
        }
        foreach ($relations as $name => $related) {
            if ($shown >= $this->maxChildren || $this->overBudget()) {
                break;
            }
            $shown++;
            $entries[] = ['key' => $this->keyString((string) $name), 'keyType' => 'relation', 'value' => $this->node($related, $depth + 1)];
        }

        return [$entries, $shown];
    }

    /**
     * The items and summary of an Eloquent collection, a Support collection holding a model, or
     * a paginator of them; null for anything else.
     *
     * @return array{0: array<mixed>, 1: array<string, mixed>}|null
     */
    private static function modelListOf(object $value): ?array
    {
        $meta = [];
        $collection = $value;
        if (is_a($value, 'Illuminate\Pagination\AbstractPaginator') || is_a($value, 'Illuminate\Pagination\AbstractCursorPaginator')) {
            $properties = self::propertiesOf($value);
            $collection = $properties["\0*\0items"] ?? null;
            if (!is_object($collection)) {
                return null;
            }
            foreach (['total' => 'total', 'currentPage' => 'page', 'lastPage' => 'lastPage', 'perPage' => 'perPage'] as $property => $field) {
                $number = $properties["\0*\0" . $property] ?? null;
                if (is_int($number)) {
                    $meta[$field] = $number;
                }
            }
            if (is_bool($properties["\0*\0hasMore"] ?? null)) {
                $meta['hasMore'] = $properties["\0*\0hasMore"];
            }
        }
        if (!is_a($collection, 'Illuminate\Support\Collection')) {
            return null;
        }
        $items = self::arrayProperty(self::propertiesOf($collection), 'items');
        $eloquent = is_a($collection, 'Illuminate\Database\Eloquent\Collection');
        $class = null;
        $mixed = false;
        $holdsModel = false;
        foreach ($items as $item) {
            if (!is_a($item, 'Illuminate\Database\Eloquent\Model')) {
                $mixed = true;
                continue;
            }
            $holdsModel = true;
            if ($class === null) {
                $class = get_class($item);
            } elseif ($class !== get_class($item)) {
                $mixed = true;
            }
        }
        if (!$eloquent && !$holdsModel) {
            return null;
        }
        $meta = ['count' => count($items)] + $meta;
        if ($class !== null && !$mixed) {
            $meta['of'] = \Runlet\Inspector::className($class);
        }
        if ($collection !== $value) {
            $meta['items'] = \Runlet\Inspector::className(get_class($collection));
        }

        return [$items, $meta];
    }

    /** @return array<string, mixed> an object's properties, read without running its code */
    private static function propertiesOf(object $value): array
    {
        return function_exists('get_mangled_object_vars') ? get_mangled_object_vars($value) : (array) $value;
    }

    /**
     * A protected array property (`attributes`, `items`, …), or [] when it isn't an array.
     *
     * @param array<string, mixed> $properties
     * @return array<mixed>
     */
    private static function arrayProperty(array $properties, string $name): array
    {
        $value = $properties["\0*\0" . $name] ?? null;

        return is_array($value) ? $value : [];
    }

    /**
     * A model key as text: scalars as they are, an object with one scalar property (a BSON
     * ObjectId's `oid`) by that property; null for anything else.
     *
     * @param mixed $key
     */
    private static function keyText($key): ?string
    {
        if (is_int($key) || is_string($key)) {
            return (string) $key;
        }
        if (is_float($key)) {
            return ValueNormalizer::floatString($key);
        }
        if (is_object($key) && !$key instanceof \Closure) {
            $properties = self::propertiesOf($key);
            if (count($properties) === 1) {
                $only = reset($properties);
                if (is_int($only) || is_string($only)) {
                    return (string) $only;
                }
            }
        }

        return null;
    }

    /**
     * Whether an attribute still equals its original value, the way Eloquent's dirty check
     * compares raw values (without casts): identical, or the same number written differently.
     * Dates compare by instant, objects of PHP's or an extension's classes (BSON ObjectId,
     * UTCDateTime) by their own comparison; other objects only when they are the same object.
     * Arrays compare entry by entry, eight levels deep.
     *
     * @param mixed $value
     * @param mixed $original
     */
    private static function sameValue($value, $original, int $depth): bool
    {
        if (is_array($value) || is_array($original)) {
            if (!is_array($value) || !is_array($original) || count($value) !== count($original)) {
                return false;
            }
            if ($depth >= 8) {
                return true;
            }
            foreach ($value as $key => $item) {
                if (!array_key_exists($key, $original) || !self::sameValue($item, $original[$key], $depth + 1)) {
                    return false;
                }
            }

            return true;
        }
        if ($value === $original) {
            return true;
        }
        if (is_object($value) || is_object($original)) {
            if (!is_object($value) || !is_object($original) || get_class($value) !== get_class($original)) {
                return false;
            }
            if ($value instanceof \DateTimeInterface || (new \ReflectionClass($value))->isInternal()) {
                try {
                    return $value == $original;
                } catch (\Throwable $error) {
                    return false;
                }
            }

            return false;
        }
        if ($value === null || $original === null || is_bool($value) || is_bool($original)) {
            return false;
        }

        return is_numeric($value) && is_numeric($original) && strcmp((string) $value, (string) $original) === 0;
    }
}
