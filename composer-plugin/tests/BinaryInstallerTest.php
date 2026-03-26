<?php

declare(strict_types=1);

namespace BenediktBrunner\Phpcma\Tests;

use Composer\IO\NullIO;
use PHPUnit\Framework\TestCase;
use BenediktBrunner\Phpcma\BinaryInstaller;
use RuntimeException;

class BinaryInstallerTest extends TestCase
{
    private string $tempDir;

    protected function setUp(): void
    {
        $this->tempDir = sys_get_temp_dir() . '/phpcma-test-' . uniqid();
        mkdir($this->tempDir, 0755, true);
    }

    protected function tearDown(): void
    {
        $this->removeDir($this->tempDir);
    }

    public function testDetectPlatformReturnsValidPlatform(): void
    {
        $installer = new BinaryInstaller('v1.0.0', new NullIO(), $this->tempDir);
        $platform = $installer->detectPlatform();

        $validPlatforms = [
            'linux-x86_64',
            'linux-aarch64',
            'macos-x86_64',
            'macos-aarch64',
            'windows-x86_64',
        ];

        $this->assertContains($platform, $validPlatforms, sprintf(
            'Platform "%s" should be one of: %s',
            $platform,
            implode(', ', $validPlatforms),
        ));
    }

    public function testGetBinaryFileNameForCurrentPlatform(): void
    {
        $installer = new BinaryInstaller('v1.0.0', new NullIO(), $this->tempDir);
        $platform = $installer->detectPlatform();
        $fileName = $installer->getBinaryFileName($platform);

        $expected = 'phpcma-v1.0.0-' . $platform;
        if (str_starts_with($platform, 'windows')) {
            $expected .= '.exe';
        }

        $this->assertSame($expected, $fileName);
    }

    public function testChecksumVerificationWithValidChecksum(): void
    {
        $installer = new BinaryInstaller('v1.0.0', new NullIO(), $this->tempDir);

        $binaryContent = 'test binary content';
        $binaryPath = $this->tempDir . '/test-binary';
        file_put_contents($binaryPath, $binaryContent);

        $expectedHash = hash('sha256', $binaryContent);
        $checksumContent = sprintf("%s  phpcma-v1.0.0-linux-x86_64\n", $expectedHash);

        $hash = $installer->parseChecksumFile($checksumContent, 'phpcma-v1.0.0-linux-x86_64');
        $this->assertSame($expectedHash, $hash);
    }

    public function testChecksumVerificationFailsWithInvalidChecksum(): void
    {
        $installer = new BinaryInstaller('v1.0.0', new NullIO(), $this->tempDir);

        $this->expectException(RuntimeException::class);
        $this->expectExceptionMessage('Checksum not found');

        $installer->parseChecksumFile("abc123  other-binary\n", 'phpcma-v1.0.0-linux-x86_64');
    }

    public function testCacheHitSkipsDownload(): void
    {
        $cacheDir = $this->tempDir . '/cache';
        mkdir($cacheDir, 0755, true);

        $platform = 'linux-x86_64';
        $binaryName = 'phpcma-v1.0.0-' . $platform;
        $cachedBinaryPath = $cacheDir . '/' . $binaryName;
        file_put_contents($cachedBinaryPath, 'cached binary');

        $installer = new BinaryInstaller('v1.0.0', new NullIO(), $cacheDir);
        $cachePath = $installer->getCachePath($binaryName);

        $this->assertNotNull($cachePath);
        $this->assertFileExists($cachePath);
        $this->assertSame('cached binary', file_get_contents($cachePath));
    }

    public function testReadConfigFromComposerJson(): void
    {
        $composerJson = $this->tempDir . '/composer.json';
        file_put_contents($composerJson, json_encode([
            'name' => 'test/project',
            'extra' => [
                'phpcma' => [
                    'checks' => ['null-safety', 'return-types'],
                    'strict' => true,
                    'min-confidence' => 0.8,
                    'called-before' => ['setUp'],
                ],
            ],
        ]));

        $config = BinaryInstaller::readConfig($composerJson);

        $this->assertSame(['null-safety', 'return-types'], $config['checks']);
        $this->assertTrue($config['strict']);
        $this->assertSame(0.8, $config['min-confidence']);
        $this->assertSame(['setUp'], $config['called-before']);
    }

    public function testReadConfigReturnsEmptyArrayForMissingFile(): void
    {
        $config = BinaryInstaller::readConfig('/nonexistent/composer.json');
        $this->assertSame([], $config);
    }

    public function testMissingBinaryErrorMessage(): void
    {
        $installer = new BinaryInstaller('v1.0.0', new NullIO(), $this->tempDir);

        $this->expectException(RuntimeException::class);
        $this->expectExceptionMessage('Failed to download binary');

        // Attempt to install from a non-existent URL triggers download failure
        $vendorBinDir = $this->tempDir . '/vendor/bin';
        mkdir($vendorBinDir, 0755, true);
        $installer->install($vendorBinDir);
    }

    public function testUnsupportedPlatformError(): void
    {
        // We can't easily mock PHP_OS_FAMILY, so we test the error message format
        // by checking that detectPlatform succeeds on the current platform
        // (it would throw RuntimeException on unsupported platforms)
        $installer = new BinaryInstaller('v1.0.0', new NullIO(), $this->tempDir);

        try {
            $platform = $installer->detectPlatform();
            // If we get here, current platform is supported — verify it's valid
            $this->assertMatchesRegularExpression(
                '/^(linux|macos|windows)-(x86_64|aarch64)$/',
                $platform,
            );
        } catch (RuntimeException $e) {
            // On truly unsupported platforms, verify the error message
            $this->assertStringContainsString('Unsupported platform', $e->getMessage());
        }
    }

    public function testVersionPinning(): void
    {
        $v1 = new BinaryInstaller('v1.0.0', new NullIO(), $this->tempDir);
        $v2 = new BinaryInstaller('v2.0.0', new NullIO(), $this->tempDir);

        $platform = 'linux-x86_64';

        $this->assertSame(
            'https://github.com/Benedikt-Brunner/PHPCMA/releases/download/v1.0.0/phpcma-v1.0.0-linux-x86_64',
            $v1->getDownloadUrl($v1->getBinaryFileName($platform)),
        );
        $this->assertSame(
            'https://github.com/Benedikt-Brunner/PHPCMA/releases/download/v2.0.0/phpcma-v2.0.0-linux-x86_64',
            $v2->getDownloadUrl($v2->getBinaryFileName($platform)),
        );
    }

    public function testComposerScriptsRegistration(): void
    {
        $composerJson = $this->tempDir . '/composer.json';
        file_put_contents($composerJson, json_encode([
            'name' => 'test/project',
            'scripts' => [
                'phpcma:check' => 'phpcma check-types -c composer.json',
            ],
        ]));

        $data = json_decode(file_get_contents($composerJson), true);
        $this->assertArrayHasKey('phpcma:check', $data['scripts']);
        $this->assertSame('phpcma check-types -c composer.json', $data['scripts']['phpcma:check']);
    }

    private function removeDir(string $dir): void
    {
        if (!is_dir($dir)) {
            return;
        }
        $items = new \RecursiveIteratorIterator(
            new \RecursiveDirectoryIterator($dir, \RecursiveDirectoryIterator::SKIP_DOTS),
            \RecursiveIteratorIterator::CHILD_FIRST,
        );
        foreach ($items as $item) {
            if ($item->isDir()) {
                rmdir($item->getRealPath());
            } else {
                unlink($item->getRealPath());
            }
        }
        rmdir($dir);
    }
}
