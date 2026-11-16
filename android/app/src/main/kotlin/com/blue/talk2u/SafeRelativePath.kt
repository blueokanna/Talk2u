package com.blue.talk2u

import java.io.File

/**
 * Path rules for archives and SAF trees that end up inside the private model
 * directory. This is the zip-slip boundary, so it is pure JVM code with its own
 * tests instead of being buried in the importer.
 */
internal object SafeRelativePath {
    /** Canonicalises a relative archive/document path, rejecting traversal. */
    fun normalize(value: String): String {
        require(value.isNotBlank() && !value.startsWith('/') && !value.startsWith('\\')) {
            "Invalid deployment path"
        }
        val segments = value.replace('\\', '/').split('/')
        require(segments.isNotEmpty() && segments.all { it.isNotEmpty() }) {
            "Invalid deployment path: $value"
        }
        return segments.joinToString("/") { validateSegment(it) }
    }

    fun validateSegment(segment: String): String {
        require(
            segment != "." &&
                segment != ".." &&
                segment.none { it == '/' || it == '\\' || it.code < 32 },
        ) { "Unsafe document name" }
        return segment
    }

    /**
     * Resolves [relative] under [root] and proves the canonical result stays
     * inside it. A path that normalises safely can still land outside through an
     * absolute drive prefix or a symlinked parent; the canonical check is what
     * actually enforces the boundary.
     */
    fun resolveIn(root: File, relative: String): File {
        val normalized = normalize(relative)
        val file = File(root, normalized.replace('/', File.separatorChar)).canonicalFile
        val canonicalRoot = root.canonicalFile
        require(file.path.startsWith(canonicalRoot.path + File.separator)) {
            "Path escapes model root"
        }
        return file
    }
}
