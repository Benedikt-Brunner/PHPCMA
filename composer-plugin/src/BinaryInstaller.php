<?php

declare(strict_types=1);

namespace BenediktBrunner\Phpcma;

use Composer\IO\IOInterface;
use RuntimeException;

class BinaryInstaller
{
    private const GITHUB_RELEASE_URL = 'https://github.com/Benedikt-Brunner/PHPCMA/releases/download';
    private const BINARY_NAME = 'phpcma';

    private string $version;
    private IOInterface $io;
    private string $cacheDir;

    public function __construct(string $version, IOInterface $io, ?string $cacheDir = null)
    {
        $this->version = $version;
        $this->io = $io;
        $this->cacheDir = $cacheDir ?? $this->defaultCacheDir();
    }

    public function install(string $vendorBinDir): void
    {
        $platform = $this->detectPlatform();
        $binaryName = $this->getBinaryFileName($platform);
        $targetPath = $vendorBinDir . DIRECTORY_SEPARATOR . self::BINARY_NAME;

        if (PHP_OS_FAMILY === 'Windows') {
            $targetPath .= '.exe';
        }

        // Check cache first
        $cachePath = $this->getCachePath($binaryName);
        if ($cachePath !== null && file_exists($cachePath)) {
            $this->io->write(sprintf(
                '<info>phpcma:</info> Using cached binary %s',
                $binaryName,
            ));
            $this->copyBinary($cachePath, $targetPath);
            return;
        }

        // Download binary
        $this->io->write(sprintf(
            '<info>phpcma:</info> Downloading %s for %s...',
            $this->version,
            $platform,
        ));

        $downloadUrl = $this->getDownloadUrl($binaryName);
        $checksumUrl = $this->getChecksumUrl();

        $tempPath = sys_get_temp_dir() . DIRECTORY_SEPARATOR . $binaryName;
        $this->download($downloadUrl, $tempPath);

        // Verify checksum
        $this->io->write('<info>phpcma:</info> Verifying SHA256 checksum...');
        $this->verifyChecksum($tempPath, $binaryName, $checksumUrl);

        // Cache the binary
        if ($cachePath !== null) {
            $cacheParent = dirname($cachePath);
            if (!is_dir($cacheParent)) {
                mkdir($cacheParent, 0755, true);
            }
            copy($tempPath, $cachePath);
        }

        // Install to vendor/bin
        $this->copyBinary($tempPath, $targetPath);
        unlink($tempPath);

        $this->io->write(sprintf(
            '<info>phpcma:</info> Binary installed to %s',
            $targetPath,
        ));
    }

    public function detectPlatform(): string
    {
        $os = PHP_OS_FAMILY;
        $arch = php_uname('m');

        $osMap = [
            'Linux' => 'linux',
            'Darwin' => 'macos',
            'Windows' => 'windows',
        ];

        $archMap = [
            'x86_64' => 'x86_64',
            'amd64' => 'x86_64',
            'aarch64' => 'aarch64',
            'arm64' => 'aarch64',
        ];

        $mappedOs = $osMap[$os] ?? null;
        $mappedArch = $archMap[$arch] ?? null;

        if ($mappedOs === null || $mappedArch === null) {
            throw new RuntimeException(sprintf(
                'Unsupported platform: %s %s. Supported: linux (x86_64, aarch64), macos (x86_64, aarch64), windows (x86_64)',
                $os,
                $arch,
            ));
        }

        if ($mappedOs === 'windows' && $mappedArch !== 'x86_64') {
            throw new RuntimeException(sprintf(
                'Unsupported platform: windows %s. Only windows x86_64 is supported.',
                $arch,
            ));
        }

        return $mappedOs . '-' . $mappedArch;
    }

    public function getBinaryFileName(string $platform): string
    {
        $name = sprintf('phpcma-%s-%s', $this->version, $platform);

        if (str_starts_with($platform, 'windows')) {
            $name .= '.exe';
        }

        return $name;
    }

    public function getDownloadUrl(string $binaryName): string
    {
        return sprintf(
            '%s/%s/%s',
            self::GITHUB_RELEASE_URL,
            $this->version,
            $binaryName,
        );
    }

    public function getChecksumUrl(): string
    {
        return sprintf(
            '%s/%s/checksums-sha256.txt',
            self::GITHUB_RELEASE_URL,
            $this->version,
        );
    }

    public function getCachePath(string $binaryName): ?string
    {
        if ($this->cacheDir === '') {
            return null;
        }

        return $this->cacheDir . DIRECTORY_SEPARATOR . $binaryName;
    }

    public function verifyChecksum(string $filePath, string $binaryName, string $checksumUrl): void
    {
        $checksumContent = @file_get_contents($checksumUrl);
        if ($checksumContent === false) {
            throw new RuntimeException(sprintf(
                'Failed to download checksums from %s',
                $checksumUrl,
            ));
        }

        $expectedHash = $this->parseChecksumFile($checksumContent, $binaryName);
        $actualHash = hash_file('sha256', $filePath);

        if ($actualHash !== $expectedHash) {
            unlink($filePath);
            throw new RuntimeException(sprintf(
                'SHA256 checksum mismatch for %s. Expected: %s, Got: %s',
                $binaryName,
                $expectedHash,
                $actualHash,
            ));
        }
    }

    public function parseChecksumFile(string $content, string $binaryName): string
    {
        $lines = explode("\n", trim($content));
        foreach ($lines as $line) {
            $line = trim($line);
            if ($line === '') {
                continue;
            }
            // Format: "<hash>  <filename>" (two spaces between hash and filename)
            $parts = preg_split('/\s+/', $line, 2);
            if ($parts === false || count($parts) !== 2) {
                continue;
            }
            if (basename(trim($parts[1])) === $binaryName) {
                return trim($parts[0]);
            }
        }

        throw new RuntimeException(sprintf(
            'Checksum not found for %s in checksums file',
            $binaryName,
        ));
    }

    private function download(string $url, string $targetPath): void
    {
        $context = stream_context_create([
            'http' => [
                'follow_location' => true,
                'timeout' => 120,
                'header' => 'User-Agent: benedikt-brunner/phpcma-composer-plugin',
            ],
        ]);

        $content = @file_get_contents($url, false, $context);
        if ($content === false) {
            throw new RuntimeException(sprintf(
                'Failed to download binary from %s',
                $url,
            ));
        }

        $dir = dirname($targetPath);
        if (!is_dir($dir)) {
            mkdir($dir, 0755, true);
        }

        file_put_contents($targetPath, $content);
    }

    private function copyBinary(string $source, string $target): void
    {
        $dir = dirname($target);
        if (!is_dir($dir)) {
            mkdir($dir, 0755, true);
        }

        copy($source, $target);

        if (PHP_OS_FAMILY !== 'Windows') {
            chmod($target, 0755);
        }
    }

    private function defaultCacheDir(): string
    {
        $home = getenv('COMPOSER_HOME');
        if ($home === false || $home === '') {
            $home = getenv('HOME');
            if ($home === false || $home === '') {
                return '';
            }
            $home .= DIRECTORY_SEPARATOR . '.composer';
        }

        return $home . DIRECTORY_SEPARATOR . 'cache' . DIRECTORY_SEPARATOR . 'phpcma';
    }

    /**
     * Read phpcma config from composer.json extra section
     *
     * @return array{checks?: string[], strict?: bool, min-confidence?: float, called-before?: string[]}
     */
    public static function readConfig(string $composerJsonPath): array
    {
        $content = @file_get_contents($composerJsonPath);
        if ($content === false) {
            return [];
        }

        $data = json_decode($content, true);
        if (!is_array($data)) {
            return [];
        }

        return $data['extra']['phpcma'] ?? [];
    }
}
