package com.example.handbeam_probe

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class RuntimeCacheEnvTest {
    @Test
    fun controlledImportRootIsCacheDirChild() {
        val cache = File("/data/user/0/com.example.handbeam_probe.foundationtest/cache")
        val root = com.example.handbeam_probe.attachments.StagingRoots.controlledImport(cache.absolutePath)
        assertEquals(File(cache, "controlled_import").absolutePath, root)
        assertTrue(root.startsWith(cache.absolutePath + File.separator))
    }
}
