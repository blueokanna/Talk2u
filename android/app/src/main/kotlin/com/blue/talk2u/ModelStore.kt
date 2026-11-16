package com.blue.talk2u

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.zip.ZipInputStream

/**
 * Raised when the selected package does not contain every file declared by the
 * deployment manifest.
 *
 * Carries the complete list so the UI can name the missing files instead of
 * showing a generic import failure.
 */
internal class MossPackageIncomplete(
    val missing: List<String>,
) : IllegalStateException(
        "The deployment package is incomplete or damaged: ${missing.joinToString(", ")}",
    )

class ModelStore(private val context: Context) {
    data class Voice(val id: String, val label: String)

    data class ModelInfo(
        val root: File,
        val totalBytes: Long,
        val voices: List<Voice>,
        val target: String,
        val qnnSdkVersion: String,
        val ortVersion: String,
    )

    data class ImportProgress(val fileName: String, val copiedBytes: Long, val totalBytes: Long)

    private data class SourceDocument(val uri: Uri, val size: Long)

    private val modelParent = File(context.noBackupFilesDir, "models")
    val installedRoot: File = File(modelParent, "moss-qnn-v81")

    fun inspectInstalled(): ModelInfo? {
        if (!installedRoot.isDirectory) return null
        return runCatching { inspectPackage(installedRoot, verifyHashes = false) }.getOrNull()
    }

    fun deleteInstalled() {
        deletePrivateTree(installedRoot)
    }

    fun importFromZip(zipUri: Uri, progress: (ImportProgress) -> Unit): ModelInfo {
        val resolver = context.contentResolver

        modelParent.mkdirs()
        check(modelParent.isDirectory) { "Cannot create the private model directory" }
        val staging = File(modelParent, ".moss-qnn-v81-import")
        val backup = File(modelParent, ".moss-qnn-v81-backup")
        deletePrivateTree(staging)
        check(staging.mkdirs()) { "Cannot create model import staging directory" }

        try {
            var extracted = 0L
            var extractedFiles = 0
            val extractedPaths = HashSet<String>()
            resolver.openInputStream(zipUri)?.use { input ->
                ZipInputStream(BufferedInputStream(input)).use { zip ->
                    while (true) {
                        if (Thread.currentThread().isInterrupted)
                            throw InterruptedException("Model import cancelled")
                        val entry = zip.nextEntry ?: break
                        if (entry.isDirectory) continue

                        val name = entry.name.trimStart('/').replace('\\', '/')
                        require(name.isNotBlank()) { "ZIP contains empty file name" }
                        val normalizedName = SafeRelativePath.normalize(name)
                        require(extractedPaths.add(normalizedName)) {
                            "ZIP contains a duplicate file: $normalizedName"
                        }
                        extractedFiles += 1
                        require(extractedFiles <= MAX_FILE_COUNT + 1) {
                            "ZIP contains too many files"
                        }
                        require(entry.size < 0L || entry.size <= MAX_FILE_BYTES) {
                            "ZIP entry is too large: $normalizedName"
                        }

                        val dest = resolveSafe(staging, normalizedName)
                        dest.parentFile?.let { parent ->
                            check(parent.mkdirs() || parent.isDirectory) {
                                "Cannot create directory for $normalizedName"
                            }
                        }

                        FileOutputStream(dest).use { output ->
                            val buffer = ByteArray(COPY_BUFFER_BYTES)
                            var fileBytes = 0L
                            while (true) {
                                if (Thread.currentThread().isInterrupted) {
                                    throw InterruptedException("Model import cancelled")
                                }
                                val count = zip.read(buffer)
                                if (count < 0) break
                                output.write(buffer, 0, count)
                                fileBytes += count
                                extracted += count
                                require(fileBytes <= MAX_FILE_BYTES) {
                                    "ZIP entry is too large: $normalizedName"
                                }
                                require(extracted <= MAX_PACKAGE_BYTES + MAX_MANIFEST_BYTES) {
                                    "ZIP expands beyond the model package limit"
                                }
                            }
                            output.fd.sync()
                        }
                        progress(ImportProgress(normalizedName, extracted, 0L))
                    }
                }
            } ?: error("Cannot open the ZIP archive")

            // Locate the deployment manifest inside the extracted tree. It may live at the
            // archive root, inside a single top-level wrapper directory, or be named with
            // the common "qqn" typo (moss-qqn-deployment.json) instead of "qnn".
            val manifestFile = findDeploymentManifest(staging)
                ?: error(
                    "The ZIP archive does not contain $DEPLOYMENT_MANIFEST. " +
                        "Make sure the selected ZIP is a moss-qnn-v81-streaming deployment package."
                )
            val effectiveRoot = manifestFile.parentFile
                ?: error("Cannot resolve the deployment manifest directory")
            require(effectiveRoot.isDirectory) { "Deployment manifest directory is missing" }
            val canonicalManifest = File(effectiveRoot, DEPLOYMENT_MANIFEST)
            if (manifestFile.name != DEPLOYMENT_MANIFEST) {
                require(!canonicalManifest.exists() && manifestFile.renameTo(canonicalManifest)) {
                    "Cannot normalize the deployment manifest name"
                }
            }

            // Do not trust ZIP CRCs. Validate every declared file against the signed
            // deployment manifest before replacing a working installation.
            val stagedInfo = inspectPackage(effectiveRoot, verifyHashes = true)
            progress(ImportProgress(DEPLOYMENT_MANIFEST, stagedInfo.totalBytes, stagedInfo.totalBytes))
            activateImportedRoot(staging, effectiveRoot, backup)
            return stagedInfo.copy(root = installedRoot)
        } catch (error: Throwable) {
            runCatching { deletePrivateTree(staging) }
            throw error
        }
    }

    private fun findDeploymentManifest(root: File): File? {
        val queue = ArrayDeque<File>()
        queue.add(root)
        while (queue.isNotEmpty()) {
            val dir = queue.removeFirst()
            val children = dir.listFiles() ?: continue
            for (child in children) {
                if (child.isDirectory) {
                    queue.add(child)
                } else if (isDeploymentManifestName(child.name)) {
                    return child
                }
            }
        }
        return null
    }

    private fun isDeploymentManifestName(name: String): Boolean {
        val lower = name.lowercase()
        return lower == DEPLOYMENT_MANIFEST || lower == "moss-qqn-deployment.json"
    }

    fun importFromTree(treeUri: Uri, progress: (ImportProgress) -> Unit): ModelInfo {
        val resolver = context.contentResolver
        val documents = indexTree(resolver, treeUri)
        val manifestDocument = documents[DEPLOYMENT_MANIFEST]
            ?: error("Select the prepared package directory containing $DEPLOYMENT_MANIFEST")
        require(manifestDocument.size < 0 || manifestDocument.size in 1..MAX_MANIFEST_BYTES) {
            "Invalid deployment manifest size"
        }
        val manifestBytes = resolver.openInputStream(manifestDocument.uri)?.use { input ->
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                require(output.size().toLong() + count <= MAX_MANIFEST_BYTES) {
                    "Deployment manifest is too large"
                }
                output.write(buffer, 0, count)
            }
            output.toByteArray()
        }
            ?: error("Cannot read $DEPLOYMENT_MANIFEST")
        require(manifestBytes.size.toLong() <= MAX_MANIFEST_BYTES) { "Deployment manifest is too large" }
        val manifest = JSONObject(manifestBytes.toString(Charsets.UTF_8))
        val files = MossDeploymentParser.parse(manifest).files
        // The document tree is fully indexed, so the whole missing set is known
        // before a single byte is copied.
        val missing = files.map { it.path }.filter { documents[it] == null }
        if (missing.isNotEmpty()) throw MossPackageIncomplete(missing)
        normalizeProviderPlan(manifest)
        val totalBytes = files.sumOf { it.size }
        require(totalBytes in 1..MAX_PACKAGE_BYTES) { "Prepared model package has an invalid total size" }

        modelParent.mkdirs()
        check(modelParent.isDirectory) { "Cannot create the private model directory" }
        val staging = File(modelParent, ".moss-qnn-v81-import")
        val backup = File(modelParent, ".moss-qnn-v81-backup")
        deletePrivateTree(staging)
        check(staging.mkdirs()) { "Cannot create model import staging directory" }
        var copied = 0L
        try {
            File(staging, DEPLOYMENT_MANIFEST).writeText(
                manifest.toString(2),
                Charsets.UTF_8,
            )
            for (entry in files) {
                if (Thread.currentThread().isInterrupted) throw InterruptedException("Model import cancelled")
                val source = documents[entry.path]
                    ?: error("Prepared package is missing ${entry.path}")
                if (source.size >= 0) {
                    require(source.size == entry.size) { "Size mismatch for ${entry.path}" }
                }
                val destination = resolveSafe(staging, entry.path)
                val destinationParent = destination.parentFile
                    ?: error("Deployment file has no parent")
                check(destinationParent.mkdirs() || destinationParent.isDirectory) {
                    "Cannot create the destination for ${entry.path}"
                }
                val digest = MessageDigest.getInstance("SHA-256")
                var fileBytes = 0L
                resolver.openInputStream(source.uri)?.use { input ->
                    FileOutputStream(destination, false).use { output ->
                        val buffer = ByteArray(COPY_BUFFER_BYTES)
                        while (true) {
                            if (Thread.currentThread().isInterrupted) {
                                throw InterruptedException("Model import cancelled")
                            }
                            val count = input.read(buffer)
                            if (count < 0) break
                            output.write(buffer, 0, count)
                            digest.update(buffer, 0, count)
                            fileBytes += count
                            progress(ImportProgress(entry.path, copied + fileBytes, totalBytes))
                        }
                        output.fd.sync()
                    }
                } ?: error("Cannot open ${entry.path}")
                require(fileBytes == entry.size) { "Copied size mismatch for ${entry.path}" }
                require(digest.hexDigest() == entry.sha256) { "SHA-256 mismatch for ${entry.path}" }
                copied += fileBytes
            }
            val stagedInfo = inspectPackage(staging, verifyHashes = true)
            activateImportedRoot(staging, staging, backup)
            return stagedInfo.copy(root = installedRoot)
        } catch (error: Throwable) {
            runCatching { deletePrivateTree(staging) }
            throw error
        }
    }

    private fun activateImportedRoot(staging: File, sourceRoot: File, backup: File) {
        val canonicalStaging = staging.canonicalFile
        val canonicalSource = sourceRoot.canonicalFile
        require(
            canonicalSource == canonicalStaging ||
                canonicalSource.path.startsWith(canonicalStaging.path + File.separator),
        ) { "Imported model root is outside staging" }

        deletePrivateTree(backup)
        val hadInstalledModel = installedRoot.exists()
        if (hadInstalledModel) {
            check(installedRoot.renameTo(backup)) { "Cannot preserve the installed model" }
        }

        try {
            check(sourceRoot.renameTo(installedRoot)) { "Cannot activate the imported model" }
            if (staging.exists()) deletePrivateTree(staging)
            if (backup.exists()) deletePrivateTree(backup)
        } catch (error: Throwable) {
            runCatching {
                if (installedRoot.exists()) deletePrivateTree(installedRoot)
            }
            if (hadInstalledModel && backup.exists()) {
                check(backup.renameTo(installedRoot)) {
                    "Model activation failed and the previous installation could not be restored"
                }
            }
            throw error
        }
    }

    private fun inspectPackage(root: File, verifyHashes: Boolean): ModelInfo {
        val manifestFile = File(root, DEPLOYMENT_MANIFEST).let { canonical ->
            if (canonical.isFile) canonical else findDeploymentManifest(root)
        }
        require(manifestFile != null && manifestFile.isFile && manifestFile.length() <= MAX_MANIFEST_BYTES) {
            "Installed deployment manifest is missing"
        }
        val manifest = JSONObject(manifestFile.readText(Charsets.UTF_8))
        val deployment = MossDeploymentParser.parse(manifest)
        val files = deployment.files
        // Report every absent or truncated file at once: a partial download is the
        // most common import failure, and naming the files is what makes the error
        // actionable for the user.
        val incomplete = files.filter { entry ->
            val file = resolveSafe(root, entry.path)
            !file.isFile || file.length() != entry.size
        }
        if (incomplete.isNotEmpty()) {
            throw MossPackageIncomplete(incomplete.map { it.path })
        }
        if (verifyHashes) {
            for (entry in files) {
                require(sha256(resolveSafe(root, entry.path)) == entry.sha256) {
                    "Installed file failed SHA-256 verification: ${entry.path}"
                }
            }
        }
        val browserManifest = File(root, TTS_DIR + "/browser_poc_manifest.json")
        val browser = JSONObject(browserManifest.readText(Charsets.UTF_8))
        val voiceArray = browser.getJSONArray("builtin_voices")
        val voices = buildList {
            for (index in 0 until voiceArray.length()) {
                val item = voiceArray.getJSONObject(index)
                val id = item.getString("voice")
                val displayName = item.optString("display_name", id)
                add(Voice(id, "$displayName ($id)"))
            }
        }
        require(voices.isNotEmpty()) { "The MOSS manifest contains no voices" }
        return ModelInfo(
            root = root,
            totalBytes = files.sumOf { it.size },
            voices = voices,
            target = "${deployment.soc} / HTP ${deployment.htpArchitecture}",
            qnnSdkVersion = deployment.qnnSdkVersion,
            ortVersion = deployment.ortVersion,
        )
    }

    private fun normalizeProviderPlan(manifest: JSONObject) {
        // The reference packager historically declared the codec as QNN_HTP,
        // although QAIRT 2.48 v81 rejects that graph. Persist the execution
        // plan actually enforced by MossTtsQnnSession.
        manifest.getJSONObject("providerPlan").put("codec", "ORT_CPU")
    }

    private fun indexTree(resolver: ContentResolver, treeUri: Uri): Map<String, SourceDocument> {
        val rootId = DocumentsContract.getTreeDocumentId(treeUri)
        val result = HashMap<String, SourceDocument>()
        fun visit(parentId: String, parentPath: String, depth: Int) {
            require(depth <= MAX_TREE_DEPTH) { "Selected directory is nested too deeply" }
            val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentId)
            resolver.query(childrenUri, QUERY_COLUMNS, null, null, null)?.use { cursor ->
                val idColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                val nameColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                val mimeColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_MIME_TYPE)
                val sizeColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_SIZE)
                while (cursor.moveToNext()) {
                    val id = cursor.getString(idColumn)
                    val name = SafeRelativePath.validateSegment(
                        cursor.getString(nameColumn),
                    )
                    val path = if (parentPath.isEmpty()) name else "$parentPath/$name"
                    val mime = cursor.getString(mimeColumn)
                    if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                        visit(id, path, depth + 1)
                    } else {
                        require(result.size < MAX_FILE_COUNT) { "Selected package contains too many files" }
                        val uri = DocumentsContract.buildDocumentUriUsingTree(treeUri, id)
                        val size = if (cursor.isNull(sizeColumn)) -1 else cursor.getLong(sizeColumn)
                        require(result.put(path, SourceDocument(uri, size)) == null) {
                            "Duplicate document path: $path"
                        }
                    }
                }
            } ?: error("Cannot enumerate the selected directory")
        }
        visit(rootId, "", 0)
        return result
    }

    private fun resolveSafe(root: File, relative: String): File =
        SafeRelativePath.resolveIn(root, relative)

    private fun deletePrivateTree(file: File) {
        if (!file.exists()) return
        val canonicalParent = modelParent.canonicalFile
        val canonical = file.canonicalFile
        require(canonical.parentFile == canonicalParent) { "Refusing to delete outside the private model directory" }
        check(file.deleteRecursively()) { "Cannot clean private model staging data" }
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        FileInputStream(file).use { input ->
            val buffer = ByteArray(COPY_BUFFER_BYTES)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.hexDigest()
    }

    private fun MessageDigest.hexDigest(): String = digest().joinToString("") { "%02x".format(it) }

    companion object {
        const val DEPLOYMENT_MANIFEST = MossDeploymentParser.MANIFEST
        private const val TTS_DIR = MossDeploymentParser.TTS_DIR
        private const val MAX_MANIFEST_BYTES = 2L * 1024 * 1024
        private const val MAX_FILE_BYTES = MossDeploymentParser.MAX_FILE_BYTES
        private const val MAX_PACKAGE_BYTES = 4L * 1024 * 1024 * 1024
        private const val MAX_FILE_COUNT = MossDeploymentParser.MAX_FILE_COUNT
        private const val MAX_TREE_DEPTH = 8
        private const val COPY_BUFFER_BYTES = 1024 * 1024
        private val QUERY_COLUMNS = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
        )
    }
}
