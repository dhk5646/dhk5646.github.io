---
title: "개발"
permalink: /dev/
layout: category
author_profile: true
dev_tag: ["java", "linux", "servlet_jsp", "window"]
---
{% include group-by-array collection=site.posts field="tags" %}

{% for devTag in page.dev_tag %}
{% for tag in group_names %}
{% if devTag == tag %}
<h2 id="{{ tag | slugify }}" class="archive__subtitle">{{ tag }}</h2>
{% assign posts = group_items[forloop.index0] %}
{% for post in posts %}
{% assign category = post.categories %}
{% if category[0] == 'dev' %}
{% include archive-single.html %}
{% endif %}
{% endfor %}
{% endif %}
{% endfor %}
{% endfor %}