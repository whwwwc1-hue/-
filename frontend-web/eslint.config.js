// ESLint 9 扁平配置：只拦截真实错误（未使用变量、未定义引用、模板必要规则），
// 不做风格洁癖；.vue 的类型检查由 vue-tsc 负责，因此这里不启用需类型信息的规则。
import js from '@eslint/js'
import tseslint from 'typescript-eslint'
import pluginVue from 'eslint-plugin-vue'

export default [
  {
    ignores: ['dist/**', 'node_modules/**', 'npm-install.log']
  },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  ...pluginVue.configs['flat/essential'],
  {
    files: ['**/*.vue'],
    languageOptions: {
      parserOptions: {
        // .vue 的 <script lang="ts"> 交给 TS 解析器
        parser: tseslint.parser
      }
    }
  },
  {
    rules: {
      'no-empty': ['error', { allowEmptyCatch: true }],
      'no-unused-vars': 'off',
      '@typescript-eslint/no-unused-vars': [
        'error',
        { argsIgnorePattern: '^_', varsIgnorePattern: '^_', caughtErrors: 'none' }
      ],
      // 后端返回为手拼 JSON 字符串，接口层大量使用 any 兜底，暂不强约束
      '@typescript-eslint/no-explicit-any': 'off',
      // 视图名单词（LoginView 等）与 Element Plus 写法相关，关闭以下模板风格规则
      'vue/multi-word-component-names': 'off'
    }
  }
]
