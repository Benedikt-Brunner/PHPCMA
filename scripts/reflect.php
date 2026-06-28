#!/usr/bin/env php
<?php

declare(strict_types=1);

/**
 * PHP Reflection extraction script.
 *
 * Loads PHP source files and extracts ground truth via the Reflection API.
 * Usage: php scripts/reflect.php [--format=compact] [--autoload=vendor/autoload.php] [--file-list=files.txt] file1.php file2.php ...
 */

// --- CLI argument parsing ---

$format = 'full';
$files = [];
$autoloadFiles = [];

/**
 * Load newline-delimited file paths from a text file.
 * Empty lines are ignored.
 *
 * @return list<string>
 */
function loadFileList(string $path): array
{
    if (!is_file($path)) {
        throw new RuntimeException("File list not found: $path");
    }

    $lines = file($path, FILE_IGNORE_NEW_LINES);
    if ($lines === false) {
        throw new RuntimeException("Failed to read file list: $path");
    }

    $result = [];
    foreach ($lines as $line) {
        $line = trim($line);
        if ($line === '') {
            continue;
        }
        $result[] = $line;
    }

    return $result;
}

for ($i = 1; $i < count($argv); $i++) {
    $arg = $argv[$i];

    if ($arg === '--format=compact') {
        $format = 'compact';
        continue;
    }

    if ($arg === '--file-list') {
        if (!isset($argv[$i + 1])) {
            fwrite(STDERR, "Missing value for --file-list\n");
            exit(1);
        }
        $i++;
        try {
            $files = [...$files, ...loadFileList($argv[$i])];
        } catch (RuntimeException $e) {
            fwrite(STDERR, $e->getMessage() . "\n");
            exit(1);
        }
        continue;
    }

    if (str_starts_with($arg, '--file-list=')) {
        $path = substr($arg, strlen('--file-list='));
        try {
            $files = [...$files, ...loadFileList($path)];
        } catch (RuntimeException $e) {
            fwrite(STDERR, $e->getMessage() . "\n");
            exit(1);
        }
        continue;
    }

    if ($arg === '--autoload') {
        if (!isset($argv[$i + 1])) {
            fwrite(STDERR, "Missing value for --autoload\n");
            exit(1);
        }
        $i++;
        $autoloadFiles[] = $argv[$i];
        continue;
    }

    if (str_starts_with($arg, '--autoload=')) {
        $autoloadFiles[] = substr($arg, strlen('--autoload='));
        continue;
    }

    if (str_starts_with($arg, '--')) {
        fwrite(STDERR, "Unknown option: $arg\n");
        exit(1);
    }

    $files[] = $arg;
}

if (empty($files)) {
    fwrite(STDERR, "Usage: php scripts/reflect.php [--format=compact] [--autoload=vendor/autoload.php] [--file-list=files.txt] <file1.php> [file2.php ...]\n");
    exit(1);
}

$targetFiles = [];
foreach ($files as $file) {
    $abs = realpath($file);
    if ($abs !== false) {
        $targetFiles[$abs] = true;
    }
}

if (empty($targetFiles)) {
    fwrite(STDERR, "No valid files provided\n");
    exit(1);
}

// --- Track which classes/interfaces/traits/enums exist before loading user files ---

$builtinClasses = get_declared_classes();
$builtinInterfaces = get_declared_interfaces();
$builtinTraits = get_declared_traits();

// --- Autoloader: register each provided file's directory for spl_autoload ---

$registeredDirs = [];
foreach ($files as $file) {
    $absFile = realpath($file);
    if ($absFile === false) {
        fwrite(STDERR, "Warning: file not found: $file\n");
        continue;
    }
    $dir = dirname($absFile);
    if (!in_array($dir, $registeredDirs, true)) {
        $registeredDirs[] = $dir;
    }
}

spl_autoload_register(function (string $class) use ($registeredDirs): void {
    $relative = str_replace('\\', DIRECTORY_SEPARATOR, $class) . '.php';
    foreach ($registeredDirs as $dir) {
        $candidate = $dir . DIRECTORY_SEPARATOR . $relative;
        if (file_exists($candidate)) {
            require_once $candidate;
            return;
        }
    }
});

// --- Load files ---

$errors = [];
foreach ($autoloadFiles as $autoloadFile) {
    $absAutoload = realpath($autoloadFile);
    if ($absAutoload === false) {
        $errors[] = ['autoload' => $autoloadFile, 'error' => 'Autoload file not found'];
        continue;
    }
    try {
        require_once $absAutoload;
    } catch (\Throwable $e) {
        $errors[] = ['autoload' => $absAutoload, 'error' => $e->getMessage()];
    }
}

foreach ($files as $file) {
    $absFile = realpath($file);
    if ($absFile === false) {
        $errors[] = ['file' => $file, 'error' => 'File not found'];
        continue;
    }
    try {
        require_once $absFile;
    } catch (\Throwable $e) {
        $errors[] = ['file' => $file, 'error' => $e->getMessage()];
    }
}

// --- Determine user-defined symbols ---

$userClasses = array_diff(get_declared_classes(), $builtinClasses);
$userInterfaces = array_diff(get_declared_interfaces(), $builtinInterfaces);
$userTraits = array_diff(get_declared_traits(), $builtinTraits);

// --- Helper functions ---

function resolveType(?\ReflectionType $type): ?string
{
    if ($type === null) {
        return null;
    }
    if ($type instanceof \ReflectionNamedType) {
        return ($type->allowsNull() && $type->getName() !== 'null' && $type->getName() !== 'mixed'
            ? '?' : '') . $type->getName();
    }
    if ($type instanceof \ReflectionUnionType) {
        return implode('|', array_map(fn(\ReflectionNamedType|ReflectionIntersectionType $t) => resolveType($t), $type->getTypes()));
    }
    if ($type instanceof \ReflectionIntersectionType) {
        return implode('&', array_map(fn(\ReflectionNamedType $t) => $t->getName(), $type->getTypes()));
    }
    return (string) $type;
}

function extractParam(\ReflectionParameter $param): array
{
    $info = [
        'name' => $param->getName(),
        'type' => resolveType($param->getType()),
        'has_default' => $param->isDefaultValueAvailable(),
        'is_variadic' => $param->isVariadic(),
    ];
    return $info;
}

function extractMethod(\ReflectionMethod $method): array
{
    $info = [
        'name' => $method->getName(),
        'visibility' => $method->isPublic() ? 'public' : ($method->isProtected() ? 'protected' : 'private'),
        'is_static' => $method->isStatic(),
        'is_abstract' => $method->isAbstract(),
        'return_type' => resolveType($method->getReturnType()),
        'params' => array_map('extractParam', $method->getParameters()),
    ];
    return $info;
}

function extractProperty(\ReflectionProperty $prop): array
{
    $info = [
        'name' => $prop->getName(),
        'visibility' => $prop->isPublic() ? 'public' : ($prop->isProtected() ? 'protected' : 'private'),
        'type' => resolveType($prop->getType()),
        'is_static' => $prop->isStatic(),
        'is_readonly' => $prop->isReadOnly(),
    ];
    return $info;
}

function extractClassLike(\ReflectionClass $ref, string $format): array
{
    // Built-in enum methods/properties to exclude
    $enumBuiltinMethods = ['cases', 'from', 'tryFrom'];
    $enumBuiltinProps = ['name', 'value'];
    $isEnum = $ref->isEnum();

    $methods = [];
    foreach ($ref->getMethods() as $method) {
        // Only include methods declared in this class, not inherited
        if ($method->getDeclaringClass()->getName() !== $ref->getName()) {
            continue;
        }
        // Skip built-in enum methods
        if ($isEnum && in_array($method->getName(), $enumBuiltinMethods, true)) {
            continue;
        }
        $methods[] = extractMethod($method);
    }

    $properties = [];
    foreach ($ref->getProperties() as $prop) {
        if ($prop->getDeclaringClass()->getName() !== $ref->getName()) {
            continue;
        }
        // Skip built-in enum properties
        if ($isEnum && in_array($prop->getName(), $enumBuiltinProps, true)) {
            continue;
        }
        $properties[] = extractProperty($prop);
    }

    $info = [
        'fqcn' => $ref->getName(),
        'file' => $ref->getFileName() ?: null,
    ];

    if ($ref->isInterface()) {
        // interfaces: methods only
        $info['methods'] = $methods;
        if ($format !== 'compact') {
            $info['extends'] = $ref->getInterfaceNames() ?: [];
        }
        return $info;
    }

    if ($ref->isTrait()) {
        $info['methods'] = $methods;
        $info['properties'] = $properties;
        return $info;
    }

    // Class or enum
    $info['is_abstract'] = $ref->isAbstract();
    $info['is_final'] = $ref->isFinal();

    $parent = $ref->getParentClass();
    $info['extends'] = $parent ? $parent->getName() : null;
    $implements = $ref->getInterfaceNames();
    if ($isEnum) {
        $implements = array_filter($implements, fn(string $name) =>
            !in_array($name, ['UnitEnum', 'BackedEnum'], true));
    }
    $info['implements'] = array_values($implements);
    $info['traits'] = array_values(array_map(fn(\ReflectionClass $t) => $t->getName(),
        array_filter(
            array_map(fn(string $name) => new \ReflectionClass($name), $ref->getTraitNames())
        )
    ));

    if ($format === 'compact') {
        $info['methods'] = array_map(fn(array $m) => [
            'name' => $m['name'],
            'visibility' => $m['visibility'],
            'params' => array_map(fn(array $p) => $p['name'], $m['params']),
            'return_type' => $m['return_type'],
        ], $methods);
        $info['properties'] = array_map(fn(array $p) => [
            'name' => $p['name'],
            'type' => $p['type'],
        ], $properties);
    } else {
        $info['methods'] = $methods;
        $info['properties'] = $properties;
    }

    // Handle enums (PHP 8.1+)
    if ($ref->isEnum()) {
        $info['is_enum'] = true;
        $enumRef = new \ReflectionEnum($ref->getName());
        $info['backing_type'] = $enumRef->isBacked() ? resolveType($enumRef->getBackingType()) : null;
        $cases = [];
        foreach ($enumRef->getCases() as $case) {
            $caseInfo = ['name' => $case->getName()];
            if ($case instanceof \ReflectionEnumBackedCase) {
                $caseInfo['value'] = $case->getBackingValue();
            }
            $cases[] = $caseInfo;
        }
        $info['cases'] = $cases;
    }

    return $info;
}

// --- Extract user-defined functions (not in any class) ---

function extractFunctions(array $files): array
{
    $functions = [];
    $definedFuncs = get_defined_functions()['user'] ?? [];

    foreach ($definedFuncs as $funcName) {
        try {
            $ref = new \ReflectionFunction($funcName);
        } catch (\ReflectionException $e) {
            continue;
        }
        $funcFile = $ref->getFileName();
        if ($funcFile === false) {
            continue;
        }
        // Only include functions defined in the provided files
        $funcFileReal = realpath($funcFile);
        $match = false;
        foreach ($files as $f) {
            $fReal = realpath($f);
            if ($fReal !== false && $fReal === $funcFileReal) {
                $match = true;
                break;
            }
        }
        if (!$match) {
            continue;
        }

        $functions[] = [
            'name' => $ref->getName(),
            'file' => $funcFile,
            'return_type' => resolveType($ref->getReturnType()),
            'params' => array_map('extractParam', $ref->getParameters()),
        ];
    }

    return $functions;
}

// --- Build output ---

$output = [
    'classes' => [],
    'interfaces' => [],
    'traits' => [],
    'functions' => [],
];

foreach ($userClasses as $className) {
    try {
        $ref = new \ReflectionClass($className);
        $classFile = $ref->getFileName();
        if ($classFile === false || !isset($targetFiles[realpath($classFile) ?: ''])) {
            continue;
        }
        if ($ref->isEnum()) {
            // Enums go in classes with is_enum flag
            $output['classes'][] = extractClassLike($ref, $format);
        } else {
            $output['classes'][] = extractClassLike($ref, $format);
        }
    } catch (\ReflectionException $e) {
        $errors[] = ['class' => $className, 'error' => $e->getMessage()];
    }
}

foreach ($userInterfaces as $ifaceName) {
    try {
        $ref = new \ReflectionClass($ifaceName);
        $interfaceFile = $ref->getFileName();
        if ($interfaceFile === false || !isset($targetFiles[realpath($interfaceFile) ?: ''])) {
            continue;
        }
        $output['interfaces'][] = extractClassLike($ref, $format);
    } catch (\ReflectionException $e) {
        $errors[] = ['interface' => $ifaceName, 'error' => $e->getMessage()];
    }
}

foreach ($userTraits as $traitName) {
    try {
        $ref = new \ReflectionClass($traitName);
        $traitFile = $ref->getFileName();
        if ($traitFile === false || !isset($targetFiles[realpath($traitFile) ?: ''])) {
            continue;
        }
        $output['traits'][] = extractClassLike($ref, $format);
    } catch (\ReflectionException $e) {
        $errors[] = ['trait' => $traitName, 'error' => $e->getMessage()];
    }
}

$output['functions'] = extractFunctions($files);

if (!empty($errors)) {
    $output['errors'] = $errors;
}

echo json_encode($output, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n";
