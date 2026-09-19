package com.example.handbeam_probe

import android.util.Log
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.espresso.Espresso.onView
import androidx.test.espresso.ViewAssertion
import androidx.test.espresso.matcher.ViewMatchers.isRoot
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertTrue
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class MarkdownSpacingMeasurementTest {
    @get:Rule val ui = createComposeRule()

    @Test fun measuresNativeBlockWhitespace() {
        ui.setContent {
            NativeMarkdown("# 标题\n\n## 文本\n\n第一段**粗体**。\n\n第二段文本。\n\n## 列表\n\n- 第一项\n- 第二项\n\n> 引用\n\n## 代码\n\n```elixir\nIO.puts(\"你好\")\n```\n")
        }
        ui.waitForIdle()
        onView(isRoot()).check(ViewAssertion { root, error ->
            if (error != null) throw error
            val views = descendants(root).filterIsInstance<TextView>().toList()
            assertTrue(views.size >= 8)
            var previousBottom: Int? = null
            for (view in views) {
                val location = IntArray(2)
                view.getLocationOnScreen(location)
                val layout = requireNotNull(view.layout)
                val text = view.text.toString()
                val trailing = text.takeLastWhile { it == '\n' }.length
                assertEquals("No document separators in an independent block", 0, trailing)
                assertEquals("Only content lines occupy layout", text.count { it == '\n' } + 1, view.lineCount)
                Log.i("MarkdownSpacing", "text=${text.replace("\n", "\\n")} density=${view.resources.displayMetrics.density} y=${location[1]} height=${view.height} gap=${previousBottom?.let { location[1] - it }} lines=${view.lineCount} trailingLF=$trailing padding=${view.totalPaddingTop}/${view.totalPaddingBottom} fontPadding=${view.includeFontPadding} lineTops=${(0..view.lineCount).map { layout.getLineTop(it) }}")
                previousBottom = location[1] + view.height
            }
        })
    }

    private fun descendants(view: View): Sequence<View> = sequence {
        yield(view)
        if (view is ViewGroup) {
            for (index in 0 until view.childCount) yieldAll(descendants(view.getChildAt(index)))
        }
    }
}
