# Differential Results

Generated: `2026-03-25T10:39:00Z`

Commit: `735913f`

Work Directory: `/var/folders/1j/rtq0wcsn2yn0g8lp0dr29kb00000gn/T//phpcma-diff-corpus-F45ljb`

| Package | PHP Files | Classes Compared | Class Matches | Class Mismatches | Total Mismatches | Status |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| `symfony/console` | 132 | 114 | 3 | 111 | 769 | mismatch |
| `symfony/http-foundation` | 104 | 0 | 0 | 0 | 0 | PHPCMA report failed |
| `monolog/monolog` | 119 | 109 | 1 | 108 | 738 | mismatch |
| `guzzlehttp/guzzle` | 41 | 32 | 1 | 31 | 175 | mismatch |
| `doctrine/orm` | 453 | 403 | 12 | 391 | 2735 | mismatch |
| `phpunit/phpunit` | 878 | 802 | 0 | 802 | 3973 | mismatch |
| `league/flysystem` | 55 | 41 | 2 | 39 | 139 | mismatch |
| `nesbot/carbon` | 920 | 0 | 0 | 0 | 0 | reflection failed |
| `ramsey/uuid` | 113 | 83 | 4 | 79 | 497 | mismatch |
| `nikic/php-parser` | 269 | 0 | 0 | 0 | 0 | reflection failed |

## Mismatch Details

### `symfony/console`

- [method_field_mismatch] `Symfony\Component\Console\Application`: Method 'addCommand' return_type differs: PHPCMA='?Command', PHP='?Symfony\Component\Console\Command\Command'
- [method_field_mismatch] `Symfony\Component\Console\Application`: Method 'addCommand' param 'command' type differs: PHPCMA='callable|Command', PHP='Symfony\Component\Console\Command\Command|callable'
- [method_field_mismatch] `Symfony\Component\Console\Application`: Method 'complete' param 'input' type differs: PHPCMA='CompletionInput', PHP='Symfony\Component\Console\Completion\CompletionInput'
- [method_field_mismatch] `Symfony\Component\Console\Application`: Method 'complete' param 'suggestions' type differs: PHPCMA='CompletionSuggestions', PHP='Symfony\Component\Console\Completion\CompletionSuggestions'
- [method_field_mismatch] `Symfony\Component\Console\Application`: Method 'configureIO' param 'input' type differs: PHPCMA='InputInterface', PHP='Symfony\Component\Console\Input\InputInterface'
- [method_field_mismatch] `Symfony\Component\Console\Application`: Method 'configureIO' param 'output' type differs: PHPCMA='OutputInterface', PHP='Symfony\Component\Console\Output\OutputInterface'
- [method_field_mismatch] `Symfony\Component\Console\Application`: Method 'doRenderThrowable' param 'e' type differs: PHPCMA='\Throwable', PHP='Throwable'
- [method_field_mismatch] `Symfony\Component\Console\Application`: Method 'doRenderThrowable' param 'output' type differs: PHPCMA='OutputInterface', PHP='Symfony\Component\Console\Output\OutputInterface'
- [method_field_mismatch] `Symfony\Component\Console\Application`: Method 'doRun' param 'input' type differs: PHPCMA='InputInterface', PHP='Symfony\Component\Console\Input\InputInterface'
- [method_field_mismatch] `Symfony\Component\Console\Application`: Method 'doRun' param 'output' type differs: PHPCMA='OutputInterface', PHP='Symfony\Component\Console\Output\OutputInterface'
- [method_field_mismatch] `Symfony\Component\Console\Application`: Method 'doRunCommand' param 'command' type differs: PHPCMA='Command', PHP='Symfony\Component\Console\Command\Command'
- [method_field_mismatch] `Symfony\Component\Console\Application`: Method 'doRunCommand' param 'input' type differs: PHPCMA='InputInterface', PHP='Symfony\Component\Console\Input\InputInterface'
- [method_field_mismatch] `Symfony\Component\Console\Application`: Method 'doRunCommand' param 'output' type differs: PHPCMA='OutputInterface', PHP='Symfony\Component\Console\Output\OutputInterface'
- [method_field_mismatch] `Symfony\Component\Console\Application`: Method 'find' return_type differs: PHPCMA='Command', PHP='Symfony\Component\Console\Command\Command'
- [method_field_mismatch] `Symfony\Component\Console\Application`: Method 'get' return_type differs: PHPCMA='Command', PHP='Symfony\Component\Console\Command\Command'
- [method_field_mismatch] `Symfony\Component\Console\Application`: Method 'getCommandName' param 'input' type differs: PHPCMA='InputInterface', PHP='Symfony\Component\Console\Input\InputInterface'
- [method_field_mismatch] `Symfony\Component\Console\Application`: Method 'getDefaultHelperSet' return_type differs: PHPCMA='HelperSet', PHP='Symfony\Component\Console\Helper\HelperSet'
- [method_field_mismatch] `Symfony\Component\Console\Application`: Method 'getDefaultInputDefinition' return_type differs: PHPCMA='InputDefinition', PHP='Symfony\Component\Console\Input\InputDefinition'
- [method_field_mismatch] `Symfony\Component\Console\Application`: Method 'getDefinition' return_type differs: PHPCMA='InputDefinition', PHP='Symfony\Component\Console\Input\InputDefinition'
- [method_field_mismatch] `Symfony\Component\Console\Application`: Method 'getHelperSet' return_type differs: PHPCMA='HelperSet', PHP='Symfony\Component\Console\Helper\HelperSet'
- ... and 749 more mismatch(es)

### `symfony/http-foundation`

PHPCMA report command failed. See `/var/folders/1j/rtq0wcsn2yn0g8lp0dr29kb00000gn/T//phpcma-diff-corpus-F45ljb/symfony__http-foundation/phpcma-report.log`.

### `monolog/monolog`

- [class_field_mismatch] `Monolog\Attribute\WithMonologChannel`: Class field 'is_final' differs: PHPCMA=False, PHP=True
- [class_missing_in_php] `Monolog\DateTimeImmutable`: Class exists in PHPCMA but not PHP reflection
- [method_field_mismatch] `MonologrrorHandler`: Method '__construct' param 'logger' type differs: PHPCMA='LoggerInterface', PHP='Psr\Log\LoggerInterface'
- [method_field_mismatch] `MonologrrorHandler`: Method 'handleException' param 'e' type differs: PHPCMA='\Throwable', PHP='Throwable'
- [method_field_mismatch] `MonologrrorHandler`: Method 'register' param 'logger' type differs: PHPCMA='LoggerInterface', PHP='Psr\Log\LoggerInterface'
- [property_field_mismatch] `MonologrrorHandler`: Property 'errorLevelMap' field 'type' differs: PHPCMA=None, PHP='array'
- [property_field_mismatch] `MonologrrorHandler`: Property 'fatalLevel' field 'type' differs: PHPCMA=None, PHP='string'
- [property_field_mismatch] `MonologrrorHandler`: Property 'handleOnlyReportedErrors' field 'type' differs: PHPCMA=None, PHP='bool'
- [property_field_mismatch] `MonologrrorHandler`: Property 'hasFatalErrorHandler' field 'type' differs: PHPCMA=None, PHP='bool'
- [property_field_mismatch] `MonologrrorHandler`: Property 'lastFatalData' field 'type' differs: PHPCMA='array|null', PHP='?array'
- [property_field_mismatch] `MonologrrorHandler`: Property 'logger' field 'type' differs: PHPCMA='LoggerInterface', PHP='Psr\Log\LoggerInterface'
- [property_field_mismatch] `MonologrrorHandler`: Property 'previousExceptionHandler' field 'type' differs: PHPCMA='Closure|null', PHP='?Closure'
- [property_field_mismatch] `MonologrrorHandler`: Property 'reservedMemory' field 'type' differs: PHPCMA='string|null', PHP='?string'
- [property_field_mismatch] `MonologrrorHandler`: Property 'uncaughtExceptionLevelMap' field 'type' differs: PHPCMA=None, PHP='array'
- [method_field_mismatch] `Monolog\Formatter\ChromePHPFormatter`: Method 'format' param 'record' type differs: PHPCMA='LogRecord', PHP='Monolog\LogRecord'
- [method_field_mismatch] `Monolog\Formatter\ChromePHPFormatter`: Method 'toWildfireLevel' param 'level' type differs: PHPCMA='Level', PHP='Monolog\Level'
- [implements_mismatch] `Monolog\FormatterlasticaFormatter`: Implemented interfaces differ: PHPCMA=[], PHP=['Monolog\Formatter\FormatterInterface']
- [method_field_mismatch] `Monolog\FormatterlasticaFormatter`: Method 'format' param 'record' type differs: PHPCMA='LogRecord', PHP='Monolog\LogRecord'
- [method_field_mismatch] `Monolog\FormatterlasticaFormatter`: Method 'getDocument' return_type differs: PHPCMA='Document', PHP='Elastica\Document'
- [property_field_mismatch] `Monolog\FormatterlasticaFormatter`: Property 'index' field 'type' differs: PHPCMA=None, PHP='string'
- ... and 718 more mismatch(es)

### `guzzlehttp/guzzle`

- [class_field_mismatch] `GuzzleHttp\BodySummarizer`: Class field 'is_final' differs: PHPCMA=False, PHP=True
- [method_field_mismatch] `GuzzleHttp\BodySummarizer`: Method 'summarize' param 'message' type differs: PHPCMA='MessageInterface', PHP='Psr\Http\Message\MessageInterface'
- [method_field_mismatch] `GuzzleHttp\Client`: Method 'applyOptions' return_type differs: PHPCMA='RequestInterface', PHP='Psr\Http\Message\RequestInterface'
- [method_field_mismatch] `GuzzleHttp\Client`: Method 'applyOptions' param 'request' type differs: PHPCMA='RequestInterface', PHP='Psr\Http\Message\RequestInterface'
- [method_field_mismatch] `GuzzleHttp\Client`: Method 'buildUri' return_type differs: PHPCMA='UriInterface', PHP='Psr\Http\Message\UriInterface'
- [method_field_mismatch] `GuzzleHttp\Client`: Method 'buildUri' param 'uri' type differs: PHPCMA='UriInterface', PHP='Psr\Http\Message\UriInterface'
- [method_missing_in_phpcma] `GuzzleHttp\Client`: Method 'delete' exists in PHP reflection but not PHPCMA
- [method_missing_in_phpcma] `GuzzleHttp\Client`: Method 'deleteAsync' exists in PHP reflection but not PHPCMA
- [method_missing_in_phpcma] `GuzzleHttp\Client`: Method 'get' exists in PHP reflection but not PHPCMA
- [method_missing_in_phpcma] `GuzzleHttp\Client`: Method 'getAsync' exists in PHP reflection but not PHPCMA
- [method_missing_in_phpcma] `GuzzleHttp\Client`: Method 'head' exists in PHP reflection but not PHPCMA
- [method_missing_in_phpcma] `GuzzleHttp\Client`: Method 'headAsync' exists in PHP reflection but not PHPCMA
- [method_field_mismatch] `GuzzleHttp\Client`: Method 'invalidBody' return_type differs: PHPCMA='InvalidArgumentException', PHP='GuzzleHttp\Exception\InvalidArgumentException'
- [method_missing_in_phpcma] `GuzzleHttp\Client`: Method 'patch' exists in PHP reflection but not PHPCMA
- [method_missing_in_phpcma] `GuzzleHttp\Client`: Method 'patchAsync' exists in PHP reflection but not PHPCMA
- [method_missing_in_phpcma] `GuzzleHttp\Client`: Method 'post' exists in PHP reflection but not PHPCMA
- [method_missing_in_phpcma] `GuzzleHttp\Client`: Method 'postAsync' exists in PHP reflection but not PHPCMA
- [method_missing_in_phpcma] `GuzzleHttp\Client`: Method 'put' exists in PHP reflection but not PHPCMA
- [method_missing_in_phpcma] `GuzzleHttp\Client`: Method 'putAsync' exists in PHP reflection but not PHPCMA
- [method_field_mismatch] `GuzzleHttp\Client`: Method 'request' return_type differs: PHPCMA='ResponseInterface', PHP='Psr\Http\Message\ResponseInterface'
- ... and 155 more mismatch(es)

### `doctrine/orm`

- [class_field_mismatch] `Doctrine\ORM\AbstractQuery`: Class field 'is_abstract' differs: PHPCMA=False, PHP=True
- [method_field_mismatch] `Doctrine\ORM\AbstractQuery`: Method '__construct' param 'em' type differs: PHPCMA='EntityManagerInterface', PHP='Doctrine\ORM\EntityManagerInterface'
- [method_field_mismatch] `Doctrine\ORM\AbstractQuery`: Method '_doExecute' return_type differs: PHPCMA='Result|int', PHP='Doctrine\DBAL\Result|int'
- [method_field_mismatch] `Doctrine\ORM\AbstractQuery`: Method 'enableResultCache' param 'lifetime' type differs: PHPCMA='int|null', PHP='?int'
- [method_field_mismatch] `Doctrine\ORM\AbstractQuery`: Method 'enableResultCache' param 'resultCacheId' type differs: PHPCMA='string|null', PHP='?string'
- [method_field_mismatch] `Doctrine\ORM\AbstractQuery`: Method 'execute' param 'parameters' type differs: PHPCMA='ArrayCollection|array|null', PHP='Doctrine\Common\Collections\ArrayCollection|array|null'
- [method_field_mismatch] `Doctrine\ORM\AbstractQuery`: Method 'executeIgnoreQueryCache' param 'parameters' type differs: PHPCMA='ArrayCollection|array|null', PHP='Doctrine\Common\Collections\ArrayCollection|array|null'
- [method_field_mismatch] `Doctrine\ORM\AbstractQuery`: Method 'executeUsingQueryCache' param 'parameters' type differs: PHPCMA='ArrayCollection|array|null', PHP='Doctrine\Common\Collections\ArrayCollection|array|null'
- [method_field_mismatch] `Doctrine\ORM\AbstractQuery`: Method 'getCacheMode' return_type differs: PHPCMA='int|null', PHP='?int'
- [method_field_mismatch] `Doctrine\ORM\AbstractQuery`: Method 'getCacheRegion' return_type differs: PHPCMA='string|null', PHP='?string'
- [method_field_mismatch] `Doctrine\ORM\AbstractQuery`: Method 'getEntityManager' return_type differs: PHPCMA='EntityManagerInterface', PHP='Doctrine\ORM\EntityManagerInterface'
- [method_field_mismatch] `Doctrine\ORM\AbstractQuery`: Method 'getHydrationCache' return_type differs: PHPCMA='CacheItemPoolInterface', PHP='Psr\Cache\CacheItemPoolInterface'
- [method_field_mismatch] `Doctrine\ORM\AbstractQuery`: Method 'getHydrationCacheProfile' return_type differs: PHPCMA='QueryCacheProfile|null', PHP='?Doctrine\DBAL\Cache\QueryCacheProfile'
- [method_field_mismatch] `Doctrine\ORM\AbstractQuery`: Method 'getParameter' return_type differs: PHPCMA='Parameter|null', PHP='?Doctrine\ORM\Query\Parameter'
- [method_field_mismatch] `Doctrine\ORM\AbstractQuery`: Method 'getParameter' param 'key' type differs: PHPCMA='int|string', PHP='string|int'
- [method_field_mismatch] `Doctrine\ORM\AbstractQuery`: Method 'getParameters' return_type differs: PHPCMA='ArrayCollection', PHP='Doctrine\Common\Collections\ArrayCollection'
- [method_field_mismatch] `Doctrine\ORM\AbstractQuery`: Method 'getQueryCacheProfile' return_type differs: PHPCMA='QueryCacheProfile|null', PHP='?Doctrine\DBAL\Cache\QueryCacheProfile'
- [method_field_mismatch] `Doctrine\ORM\AbstractQuery`: Method 'getResultSetMapping' return_type differs: PHPCMA='ResultSetMapping|null', PHP='?Doctrine\ORM\Query\ResultSetMapping'
- [method_field_mismatch] `Doctrine\ORM\AbstractQuery`: Method 'getSQL' return_type differs: PHPCMA='string|array', PHP='array|string'
- [method_field_mismatch] `Doctrine\ORM\AbstractQuery`: Method 'getTimestampKey' return_type differs: PHPCMA='TimestampCacheKey|null', PHP='?Doctrine\ORM\Cache\TimestampCacheKey'
- ... and 2715 more mismatch(es)

### `phpunit/phpunit`

- [class_field_mismatch] `PHPUnitvent\Application\Finished`: Class field 'is_final' differs: PHPCMA=False, PHP=True
- [method_field_mismatch] `PHPUnitvent\Application\Finished`: Method '__construct' param 'telemetryInfo' type differs: PHPCMA='Telemetry\Info', PHP='PHPUnit\Event\Telemetry\Info'
- [method_field_mismatch] `PHPUnitvent\Application\Finished`: Method 'telemetryInfo' return_type differs: PHPCMA='Telemetry\Info', PHP='PHPUnit\Event\Telemetry\Info'
- [property_field_mismatch] `PHPUnitvent\Application\Finished`: Property 'shellExitCode' field 'type' differs: PHPCMA=None, PHP='int'
- [property_field_mismatch] `PHPUnitvent\Application\Finished`: Property 'shellExitCode' field 'is_readonly' differs: PHPCMA=False, PHP=True
- [property_field_mismatch] `PHPUnitvent\Application\Finished`: Property 'telemetryInfo' field 'type' differs: PHPCMA='Telemetry\Info', PHP='PHPUnit\Event\Telemetry\Info'
- [property_field_mismatch] `PHPUnitvent\Application\Finished`: Property 'telemetryInfo' field 'is_readonly' differs: PHPCMA=False, PHP=True
- [class_field_mismatch] `PHPUnitvent\Application\Started`: Class field 'is_final' differs: PHPCMA=False, PHP=True
- [method_field_mismatch] `PHPUnitvent\Application\Started`: Method '__construct' param 'telemetryInfo' type differs: PHPCMA='Telemetry\Info', PHP='PHPUnit\Event\Telemetry\Info'
- [method_field_mismatch] `PHPUnitvent\Application\Started`: Method '__construct' param 'runtime' type differs: PHPCMA='Runtime', PHP='PHPUnit\Event\Runtime\Runtime'
- [method_field_mismatch] `PHPUnitvent\Application\Started`: Method 'runtime' return_type differs: PHPCMA='Runtime', PHP='PHPUnit\Event\Runtime\Runtime'
- [method_field_mismatch] `PHPUnitvent\Application\Started`: Method 'telemetryInfo' return_type differs: PHPCMA='Telemetry\Info', PHP='PHPUnit\Event\Telemetry\Info'
- [property_field_mismatch] `PHPUnitvent\Application\Started`: Property 'runtime' field 'type' differs: PHPCMA='Runtime', PHP='PHPUnit\Event\Runtime\Runtime'
- [property_field_mismatch] `PHPUnitvent\Application\Started`: Property 'runtime' field 'is_readonly' differs: PHPCMA=False, PHP=True
- [property_field_mismatch] `PHPUnitvent\Application\Started`: Property 'telemetryInfo' field 'type' differs: PHPCMA='Telemetry\Info', PHP='PHPUnit\Event\Telemetry\Info'
- [property_field_mismatch] `PHPUnitvent\Application\Started`: Property 'telemetryInfo' field 'is_readonly' differs: PHPCMA=False, PHP=True
- [class_field_mismatch] `PHPUnitvent\Code\ClassMethod`: Class field 'is_final' differs: PHPCMA=False, PHP=True
- [property_field_mismatch] `PHPUnitvent\Code\ClassMethod`: Property 'className' field 'type' differs: PHPCMA=None, PHP='string'
- [property_field_mismatch] `PHPUnitvent\Code\ClassMethod`: Property 'className' field 'is_readonly' differs: PHPCMA=False, PHP=True
- [property_field_mismatch] `PHPUnitvent\Code\ClassMethod`: Property 'methodName' field 'type' differs: PHPCMA=None, PHP='string'
- ... and 3953 more mismatch(es)

### `league/flysystem`

- [class_field_mismatch] `League\Flysystem\ChecksumAlgoIsNotSupported`: Class field 'is_final' differs: PHPCMA=False, PHP=True
- [implements_mismatch] `League\Flysystem\ChecksumAlgoIsNotSupported`: Implemented interfaces differ: PHPCMA=[], PHP=['Stringable', 'Throwable']
- [method_field_mismatch] `League\Flysystem\Config`: Method 'extend' return_type differs: PHPCMA='Config', PHP='League\Flysystem\Config'
- [method_field_mismatch] `League\Flysystem\Config`: Method 'withDefaults' return_type differs: PHPCMA='Config', PHP='League\Flysystem\Config'
- [method_field_mismatch] `League\Flysystem\Config`: Method 'withSetting' return_type differs: PHPCMA='Config', PHP='League\Flysystem\Config'
- [method_field_mismatch] `League\Flysystem\Config`: Method 'withoutSettings' return_type differs: PHPCMA='Config', PHP='League\Flysystem\Config'
- [class_field_mismatch] `League\Flysystem\CorruptedPathDetected`: Class field 'is_final' differs: PHPCMA=False, PHP=True
- [implements_mismatch] `League\Flysystem\CorruptedPathDetected`: Implemented interfaces differ: PHPCMA=['League\Flysystem\FilesystemException'], PHP=['League\Flysystem\FilesystemException', 'Stringable', 'Throwable']
- [method_field_mismatch] `League\Flysystem\CorruptedPathDetected`: Method 'forPath' return_type differs: PHPCMA='CorruptedPathDetected', PHP='League\Flysystem\CorruptedPathDetected'
- [class_field_mismatch] `League\Flysystem\DecoratedAdapter`: Class field 'is_abstract' differs: PHPCMA=False, PHP=True
- [method_field_mismatch] `League\Flysystem\DecoratedAdapter`: Method '__construct' param 'adapter' type differs: PHPCMA='FilesystemAdapter', PHP='League\Flysystem\FilesystemAdapter'
- [method_field_mismatch] `League\Flysystem\DecoratedAdapter`: Method 'copy' param 'config' type differs: PHPCMA='Config', PHP='League\Flysystem\Config'
- [method_field_mismatch] `League\Flysystem\DecoratedAdapter`: Method 'createDirectory' param 'config' type differs: PHPCMA='Config', PHP='League\Flysystem\Config'
- [method_field_mismatch] `League\Flysystem\DecoratedAdapter`: Method 'fileSize' return_type differs: PHPCMA='FileAttributes', PHP='League\Flysystem\FileAttributes'
- [method_field_mismatch] `League\Flysystem\DecoratedAdapter`: Method 'lastModified' return_type differs: PHPCMA='FileAttributes', PHP='League\Flysystem\FileAttributes'
- [method_field_mismatch] `League\Flysystem\DecoratedAdapter`: Method 'mimeType' return_type differs: PHPCMA='FileAttributes', PHP='League\Flysystem\FileAttributes'
- [method_field_mismatch] `League\Flysystem\DecoratedAdapter`: Method 'move' param 'config' type differs: PHPCMA='Config', PHP='League\Flysystem\Config'
- [method_field_mismatch] `League\Flysystem\DecoratedAdapter`: Method 'visibility' return_type differs: PHPCMA='FileAttributes', PHP='League\Flysystem\FileAttributes'
- [method_field_mismatch] `League\Flysystem\DecoratedAdapter`: Method 'write' param 'config' type differs: PHPCMA='Config', PHP='League\Flysystem\Config'
- [method_field_mismatch] `League\Flysystem\DecoratedAdapter`: Method 'writeStream' param 'config' type differs: PHPCMA='Config', PHP='League\Flysystem\Config'
- ... and 119 more mismatch(es)

### `nesbot/carbon`

PHP reflection extraction failed. See `/var/folders/1j/rtq0wcsn2yn0g8lp0dr29kb00000gn/T//phpcma-diff-corpus-F45ljb/nesbot__carbon/reflect.log`.

### `ramsey/uuid`

- [implements_mismatch] `Ramsey\Uuid\Builder\BuilderCollection`: Implemented interfaces differ: PHPCMA=[], PHP=['ArrayAccess', 'Countable', 'IteratorAggregate', 'Ramsey\Collection\ArrayInterface', 'Ramsey\Collection\CollectionInterface', 'Traversable']
- [class_field_mismatch] `Ramsey\Uuid\Builder\DefaultUuidBuilder`: Class field 'extends' differs: PHPCMA='Rfc4122UuidBuilder', PHP='Ramsey\Uuid\Rfc4122\UuidBuilder'
- [implements_mismatch] `Ramsey\Uuid\Builder\DefaultUuidBuilder`: Implemented interfaces differ: PHPCMA=[], PHP=['Ramsey\Uuid\Builder\UuidBuilderInterface']
- [method_field_mismatch] `Ramsey\Uuid\Builder\DegradedUuidBuilder`: Method '__construct' param 'numberConverter' type differs: PHPCMA='NumberConverterInterface', PHP='Ramsey\Uuid\Converter\NumberConverterInterface'
- [method_field_mismatch] `Ramsey\Uuid\Builder\DegradedUuidBuilder`: Method '__construct' param 'timeConverter' type differs: PHPCMA='?TimeConverterInterface', PHP='?Ramsey\Uuid\Converter\TimeConverterInterface'
- [method_field_mismatch] `Ramsey\Uuid\Builder\DegradedUuidBuilder`: Method 'build' return_type differs: PHPCMA='UuidInterface', PHP='Ramsey\Uuid\UuidInterface'
- [method_field_mismatch] `Ramsey\Uuid\Builder\DegradedUuidBuilder`: Method 'build' param 'codec' type differs: PHPCMA='CodecInterface', PHP='Ramsey\Uuid\Codec\CodecInterface'
- [property_field_mismatch] `Ramsey\Uuid\Builder\DegradedUuidBuilder`: Property 'numberConverter' field 'type' differs: PHPCMA='NumberConverterInterface', PHP='Ramsey\Uuid\Converter\NumberConverterInterface'
- [property_field_mismatch] `Ramsey\Uuid\Builder\DegradedUuidBuilder`: Property 'timeConverter' field 'type' differs: PHPCMA='TimeConverterInterface', PHP='Ramsey\Uuid\Converter\TimeConverterInterface'
- [method_field_mismatch] `Ramsey\Uuid\Builder\FallbackBuilder`: Method 'build' return_type differs: PHPCMA='UuidInterface', PHP='Ramsey\Uuid\UuidInterface'
- [method_field_mismatch] `Ramsey\Uuid\Builder\FallbackBuilder`: Method 'build' param 'codec' type differs: PHPCMA='CodecInterface', PHP='Ramsey\Uuid\Codec\CodecInterface'
- [implements_mismatch] `Ramsey\Uuid\Codec\GuidStringCodec`: Implemented interfaces differ: PHPCMA=[], PHP=['Ramsey\Uuid\Codec\CodecInterface']
- [method_field_mismatch] `Ramsey\Uuid\Codec\GuidStringCodec`: Method 'decode' return_type differs: PHPCMA='UuidInterface', PHP='Ramsey\Uuid\UuidInterface'
- [method_field_mismatch] `Ramsey\Uuid\Codec\GuidStringCodec`: Method 'decodeBytes' return_type differs: PHPCMA='UuidInterface', PHP='Ramsey\Uuid\UuidInterface'
- [method_field_mismatch] `Ramsey\Uuid\Codec\GuidStringCodec`: Method 'encode' param 'uuid' type differs: PHPCMA='UuidInterface', PHP='Ramsey\Uuid\UuidInterface'
- [implements_mismatch] `Ramsey\Uuid\Codec\OrderedTimeCodec`: Implemented interfaces differ: PHPCMA=[], PHP=['Ramsey\Uuid\Codec\CodecInterface']
- [method_field_mismatch] `Ramsey\Uuid\Codec\OrderedTimeCodec`: Method 'decodeBytes' return_type differs: PHPCMA='UuidInterface', PHP='Ramsey\Uuid\UuidInterface'
- [method_field_mismatch] `Ramsey\Uuid\Codec\OrderedTimeCodec`: Method 'encodeBinary' param 'uuid' type differs: PHPCMA='UuidInterface', PHP='Ramsey\Uuid\UuidInterface'
- [method_field_mismatch] `Ramsey\Uuid\Codec\StringCodec`: Method '__construct' param 'builder' type differs: PHPCMA='UuidBuilderInterface', PHP='Ramsey\Uuid\Builder\UuidBuilderInterface'
- [method_field_mismatch] `Ramsey\Uuid\Codec\StringCodec`: Method 'decode' return_type differs: PHPCMA='UuidInterface', PHP='Ramsey\Uuid\UuidInterface'
- ... and 477 more mismatch(es)

### `nikic/php-parser`

PHP reflection extraction failed. See `/var/folders/1j/rtq0wcsn2yn0g8lp0dr29kb00000gn/T//phpcma-diff-corpus-F45ljb/nikic__php-parser/reflect.log`.

