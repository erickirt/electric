<script setup>
import { useData } from 'vitepress'
import { useSidebar } from 'vitepress/theme'

import DefaultTheme from 'vitepress/theme-without-fonts'

import BlogPostHeader from '../../src/components/BlogPostHeader.vue'
import NavSignupButton from '../../src/components/NavSignupButton.vue'
import SiteFooter from '../../src/components/SiteFooter.vue'
import UseCaseHeader from '../../src/components/UseCaseHeader.vue'

import HomeFeaturesAfter from '../../src/partials/home-features-after.md'
import HomeFeaturesBefore from '../../src/partials/home-features-before.md'

const { Layout } = DefaultTheme

const { frontmatter } = useData()
const { hasSidebar } = useSidebar()
</script>

<template>
  <Layout>
    <template #nav-bar-content-after>
      <NavSignupButton />
    </template>
    <template #home-features-before>
      <div class="vp-doc">
        <div class="container">
          <div class="features-content">
            <HomeFeaturesBefore />
          </div>
        </div>
      </div>
    </template>
    <template #home-features-after>
      <div class="vp-doc">
        <div class="container">
          <div class="features-content">
            <HomeFeaturesAfter />
          </div>
        </div>
      </div>
    </template>
    <template #doc-before>
      <div class="vp-doc" v-if="frontmatter.case">
        <UseCaseHeader />
      </div>
      <div class="vp-doc" v-if="frontmatter.post">
        <BlogPostHeader />
      </div>
    </template>
    <template #layout-bottom>
      <SiteFooter v-if="!hasSidebar" />
    </template>
  </Layout>
</template>