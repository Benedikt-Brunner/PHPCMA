<?php
namespace Test;

class ReturnTypeBad
{
    /** Return mismatch: declared int, returns string */
    public function mismatch(): int
    {
        return "not an int";
    }

    /** Missing return in non-void */
    public function missingReturn(): int
    {
        $x = 1;
    }

    /** Return null in non-nullable */
    public function nullNonNullable(): int
    {
        return null;
    }

    /** Void method returns a value */
    public function voidWithValue(): void
    {
        return 42;
    }

    /** If/else with one bad branch */
    public function badBranch(bool $flag): int
    {
        if ($flag) {
            return 1;
        } else {
            return "wrong";
        }
    }
}
